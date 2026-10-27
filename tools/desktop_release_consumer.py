"""Consume a desktop CPU release in a disposable runtime container."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import platform
import shutil
import sys
import tarfile
import tempfile

from desktop_context_benchmark import Native, request


def digest(path):
    checksum = hashlib.sha256()
    with open(path, 'rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            checksum.update(block)
    return checksum.hexdigest()


def extract_library(archive, checksum_file, member, target):
    entries = [line.split() for line in checksum_file.read_text().splitlines()]
    expected = [row[0] for row in entries
                if len(row) == 2 and row[1].lstrip('*') == archive.name]
    if len(expected) != 1 or digest(archive) != expected[0]:
        raise ValueError('Release archive checksum mismatch or ambiguous entry')
    with tarfile.open(archive, 'r:gz') as package:
        matches = [entry for entry in package.getmembers()
                   if entry.name.removeprefix('./') == member]
        if len(matches) != 1 or not matches[0].isfile():
            raise ValueError('Expected one regular native library member')
        with package.extractfile(matches[0]) as source, target.open('xb') as destination:
            shutil.copyfileobj(source, destination)


def windows_runtime_modules():
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetModuleHandleW.argtypes = [ctypes.c_wchar_p]
    kernel.GetModuleHandleW.restype = ctypes.c_void_p
    kernel.GetModuleFileNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_uint32]
    kernel.GetModuleFileNameW.restype = ctypes.c_uint32
    modules = {}
    for name in ('MSVCP140.dll', 'VCRUNTIME140.dll', 'VCRUNTIME140_1.dll', 'ucrtbase.dll'):
        handle = kernel.GetModuleHandleW(name)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        buffer = ctypes.create_unicode_buffer(32768)
        length = kernel.GetModuleFileNameW(handle, buffer, len(buffer))
        if not length or length >= len(buffer):
            raise ctypes.WinError(ctypes.get_last_error())
        modules[name] = {'path': buffer.value, 'sha256': digest(buffer.value)}
    return modules


def consume(args, evidence):
    names = ('cmake', 'cc', 'gcc', 'g++', 'c++', 'clang', 'clang++', 'make', 'ninja', 'nvcc')
    if sys.platform == 'win32':
        names += ('cl', 'link', 'msbuild')
    tools = {name: shutil.which(name) for name in names}
    evidence.update(platform=platform.platform(), machine=platform.machine(),
                    python=platform.python_version(), native_build_tools=tools,
                    version=args.version, archive_sha256=digest(args.archive),
                    member=args.member, model_sha256=digest(args.model))
    assert not any(tools.values()), tools
    assert evidence['model_sha256'] == 'e6d47b7c6316612da747c4e471d10f5f1b87c8bf6051332d80f4810d69196c64'
    temporary = tempfile.mkdtemp(prefix='libllama-release-')
    try:
        library = Path(temporary) / Path(args.member).name
        extract_library(Path(args.archive), Path(args.checksum_file), args.member, library)
        evidence['library_sha256'] = digest(library)
        config = {'model_path': str(Path(args.model).resolve()), 'n_ctx': 512,
                  'n_batch': 64, 'n_ubatch': 64, 'n_threads': 2, 'n_threads_batch': 2,
                  'n_gpu_layers': 0, 'n_parallel': 1, 'backend': 'cpu', 'require_backend': True}
        engine = Native(str(library), config)
        try:
            evidence['caps'] = engine.caps()
            assert evidence['caps']['selected_backend'] == 'cpu'
            assert not evidence['caps']['degradation'], evidence['caps']
            evidence['load_seconds'] = engine.load_seconds
            body = request('Reply with the word ready.', 16)
            evidence['budget'] = engine.prepare(body)
            assert evidence['budget']['fits'], evidence['budget']
            evidence['inference'] = engine.run(body, timeout=120)
            usage = evidence['inference']['usage']
            assert usage['total_tokens'] == usage['prompt_tokens'] + usage['completion_tokens'], usage
            evidence['stats'] = engine.stats()
            assert all(evidence['stats'][key] == 0 for key in (
                'active_tasks', 'retained_tasks', 'pending_cancellations', 'buffered_bytes', 'buffered_events'))
            if sys.platform == 'win32':
                evidence['loaded_runtime_modules'] = windows_runtime_modules()
        finally:
            engine.close()
            evidence['engine_destroy_returned'] = True
    finally:
        if sys.platform == 'win32':
            # The DLL stays mapped for the process lifetime. The disposable
            # container owns this directory and removes it after Python exits.
            evidence['extraction_cleanup_owner'] = 'container removal after process exit'
        else:
            shutil.rmtree(temporary)
            evidence['extraction_cleanup_owner'] = 'consumer temporary directory'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('archive', 'checksum-file', 'member', 'model', 'version', 'output'):
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    evidence = {}
    try:
        consume(args, evidence)
        evidence['status'] = 'passed'
    except BaseException as error:
        evidence.update(status='failed', error=repr(error))
        raise
    finally:
        Path(args.output).write_text(json.dumps(evidence, indent=2), encoding='utf-8')
