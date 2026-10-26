"""Bounded direct ABI tests with upstream sampler/grammar, no model or GPU.
Run: python3 packages/lib_llama_cpp_ffi/test/native/test_direct_safe.py
"""
import ctypes
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
UPSTREAM = ROOT / 'third_party/llama.cpp'


def build(path, wrapper=False):
    command = ['c++', '-std=c++17', '-shared', '-fPIC', '-O0',
               '-ffunction-sections', '-fdata-sections']
    if sys.platform == 'darwin':
        command += ['-Wl,-undefined,dynamic_lookup']
    else:
        # Retain the tested APIs, not unrelated chat/media functions whose
        # inline Jinja code introduces eager RTTI relocations on ELF loaders.
        exports = path.with_suffix('.exports')
        exports.write_text('{ global: direct_test_*; lib_llama_cpp_*_safe; '
                           'lib_llama_cpp_string_free; local: *; };\n')
        command += [f'-Wl,--version-script={exports}', '-Wl,--gc-sections']
    for include in ['include', 'src', 'ggml/include', 'common', 'vendor', 'tools/mtmd']:
        command += ['-I', str(UPSTREAM / include)]
    command += ['-I', str(ROOT / 'packages/lib_llama_cpp_ffi/include')]
    command += [str(HERE / 'direct_safe_fixture.cpp'),
                str(UPSTREAM / 'src/llama-sampler.cpp'),
                str(UPSTREAM / 'src/llama-grammar.cpp')]
    if wrapper:
        wrapper_object = path.with_suffix('.wrapper.o')
        wrapper_command = command[:]
        wrapper_command.remove('-shared')
        wrapper_command = [item for item in wrapper_command if not item.startswith('-Wl,')]
        wrapper_command = wrapper_command[:wrapper_command.index(str(HERE / 'direct_safe_fixture.cpp'))]
        wrapper_command += ['-Dllama_sampler_chain_add=direct_test_chain_add', '-c',
                            str(ROOT / 'packages/lib_llama_cpp_ffi/src/lib_llama_cpp_wrapper.cc'),
                            '-o', str(wrapper_object)]
        result = subprocess.run(wrapper_command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        command += [str(wrapper_object)]
    command += ['-o', str(path)]
    def compile_library():
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
    compile_library()
    # ctypes uses RTLD_NOW. Supply aborting stubs only for unexercised project
    # dependencies of the upstream translation units; any accidental use fails.
    undefined = subprocess.check_output(['nm', '-u', str(path)], text=True)
    symbols = [line.split()[-1] for line in undefined.splitlines() if line.strip()]
    if sys.platform == 'darwin':
        symbols = [name[1:] if name.startswith('_') else name for name in symbols]
    decoded = subprocess.check_output(['c++filt', *symbols], text=True).splitlines()
    missing = [name for name, demangled in zip(symbols, decoded)
               if re.match(r'(ggml_|llama_|common_|mtmd_|unicode_|lib_llama_cpp_|format\(|time_meas)', demangled)]
    stubs = path.with_suffix('.unused.cpp')
    stubs.write_text('#include <cstdio>\n#include <cstdlib>\n' + ''.join(
        f'extern "C" void unused_{i}() asm("{("_" if sys.platform == "darwin" else "") + name}");\n'
        f'void unused_{i}() {{ std::fputs("unexpected fixture dependency: {name}\\n", stderr); std::abort(); }}\n'
        for i, name in enumerate(missing)))
    command.insert(-2, str(stubs))
    compile_library()


def native_case(library, name):
    lib = ctypes.CDLL(library, mode=os.RTLD_LAZY)
    if name == 'duplicate':
        lib.direct_test_duplicate_accept()
        return
    lib.direct_test_safe_operation.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    lib.lib_llama_cpp_string_free.argtypes = [ctypes.c_void_p]
    lib.direct_test_live_allocations.restype = ctypes.c_long
    def operation(index, fault=0):
        error = ctypes.c_void_p()
        status = lib.direct_test_safe_operation(index, fault, ctypes.byref(error))
        try:
            body = json.loads(ctypes.string_at(error).decode()) if error.value else None
        finally:
            if error.value:
                lib.lib_llama_cpp_string_free(error)
        return status, body
    if name == 'exceptions':
        for index in range(8):
            for fault in ([1] if index == 5 else [1, 2, 3]):
                status, error = operation(index, fault)
                assert status == -1, (index, fault, status, error)
                assert error['code'] == ('allocation' if fault == 1 else 'backend'), (index, fault, error)
                assert operation(index) == (0, None), ('recovery failed', index)
    elif name == 'single_accept':
        assert operation(6) == (0, None)
    elif name == 'caught_duplicate':
        lib.lib_llama_cpp_sampler_create_safe.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        lib.lib_llama_cpp_sampler_create_safe.restype = ctypes.c_void_p
        lib.lib_llama_cpp_sampler_sample_safe.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_void_p)]
        lib.lib_llama_cpp_sampler_accept_safe.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
        lib.lib_llama_cpp_sampler_free_safe.argtypes = [ctypes.c_void_p]
        error = ctypes.c_void_p()
        sampler = lib.lib_llama_cpp_sampler_create_safe(0x1000, json.dumps({"grammar": 'root ::= "a"'}).encode(), ctypes.byref(error))
        assert sampler and not error.value
        try:
            token = ctypes.c_int()
            assert lib.lib_llama_cpp_sampler_sample_safe(sampler, 0x3000, -1, ctypes.byref(token), ctypes.byref(error)) == 0
            assert lib.lib_llama_cpp_sampler_accept_safe(sampler, token.value, ctypes.byref(error)) == -1
            body = json.loads(ctypes.string_at(error).decode())
            assert body['code'] == 'backend' and 'Unexpected empty grammar stack' in body['message'], body
            lib.lib_llama_cpp_string_free(error)
        finally:
            lib.lib_llama_cpp_sampler_free_safe(sampler)
        assert operation(6) == (0, None)
    elif name == 'capacities':
        function = lib.lib_llama_cpp_tokenize_safe
        function.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_int,
                             ctypes.c_bool, ctypes.c_bool, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_void_p)]
        token = ctypes.c_int()
        result = ctypes.c_int()
        error = ctypes.c_void_p()
        assert function(0x1000, b'a', 1, ctypes.byref(token), 0, False, False, ctypes.byref(result), ctypes.byref(error)) == 0
        assert result.value == -1 and not error.value
        assert function(0x1000, b'a', 1, ctypes.byref(token), 1, False, False, ctypes.byref(result), ctypes.byref(error)) == 0
        assert result.value == 1 and token.value == 0 and not error.value
    elif name == 'chain_ownership':
        assert operation(5) == (0, None)  # warm static sampler state
        before = lib.direct_test_live_allocations()
        status, error = operation(5, 4)  # fail actual vector allocation in chain_add
        assert status == -1 and error['code'] == 'allocation', (status, error)
        after = lib.direct_test_live_allocations()
        assert before == after, ('chain/child leaked or double-freed', before, after)
        assert operation(5) == (0, None)
    else:
        raise AssertionError(name)


class DirectSafeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='direct_safe_')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.library = str(Path(cls.temp.name) / 'fixture.so')
        build(Path(cls.library), wrapper=True)

    def test_exception_boundaries_and_recovery(self):
        self.run_case('exceptions')

    def test_sample_accepts_exactly_once(self):
        self.run_case('single_accept')

    def test_duplicate_accept_exception_is_contained(self):
        self.run_case('caught_duplicate')

    def test_negative_token_buffer_count_is_not_an_exception(self):
        self.run_case('capacities')

    def test_raw_duplicate_accept_reproduces_original_crash(self):
        result = subprocess.run([sys.executable, __file__, '--case', self.library, 'duplicate'],
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Unexpected empty grammar stack', result.stderr)

    def test_chain_add_failure_releases_child_and_chain(self):
        self.run_case('chain_ownership')

    def run_case(self, name):
        result = subprocess.run([sys.executable, __file__, '--case', self.library, name],
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    if '--raw-repro' in sys.argv:
        with tempfile.TemporaryDirectory(prefix='direct_safe_red_') as temp:
            library = Path(temp) / 'fixture.so'
            build(library)
            result = subprocess.run([sys.executable, __file__, '--case', str(library), 'duplicate'],
                                    capture_output=True, text=True, timeout=15)
            print(result.stderr, end='')
            print(f'duplicate accept subprocess exit: {result.returncode}')
            sys.exit(result.returncode)
    elif '--case' in sys.argv:
        native_case(sys.argv[-2], sys.argv[-1])
    else:
        unittest.main()
