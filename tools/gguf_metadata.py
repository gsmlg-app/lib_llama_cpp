#!/usr/bin/env python3
"""Read reproducibility metadata without loading weights or third-party packages."""
import argparse
import hashlib
import json
import struct


def metadata(path):
    with open(path, 'rb') as file:
        def unpack(fmt):
            return struct.unpack('<' + fmt, file.read(struct.calcsize('<' + fmt)))[0]
        def string(keep=True):
            size = unpack('Q')
            if keep:
                return file.read(size).decode('utf-8')
            file.seek(size, 1)
        def value(kind, keep):
            formats = {0:'B', 1:'b', 2:'H', 3:'h', 4:'I', 5:'i', 6:'f', 7:'?', 10:'Q', 11:'q', 12:'d'}
            if kind in formats:
                return unpack(formats[kind])
            if kind == 8:
                return string(keep)
            if kind == 9:
                element, count = unpack('I'), unpack('Q')
                if not keep and element in formats:
                    file.seek(struct.calcsize('<' + formats[element]) * count, 1)
                    return None
                return [value(element, keep) for _ in range(count)] if keep else _skip_array(element, count)
            raise ValueError(f'Unsupported GGUF value type {kind}')
        def _skip_array(kind, count):
            for _ in range(count):
                value(kind, False)
        assert file.read(4) == b'GGUF', 'Invalid GGUF magic'
        version, tensors, pairs = unpack('I'), unpack('Q'), unpack('Q')
        result = {'gguf_version': version, 'tensor_count': tensors}
        for _ in range(pairs):
            key, kind = string(), unpack('I')
            keep = (key.startswith('general.') or key.endswith('.context_length') or
                    key.startswith('tokenizer.chat_template') or key.endswith('.sliding_window') or
                    key in ['tokenizer.ggml.model', 'tokenizer.ggml.bos_token_id', 'tokenizer.ggml.eos_token_id'])
            item = value(kind, keep)
            if keep:
                result[key] = item
    with open(path, 'rb') as file:
        result['sha256'] = hashlib.file_digest(file, 'sha256').hexdigest()
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model')
    args = parser.parse_args()
    print(json.dumps(metadata(args.model), indent=2, ensure_ascii=False))
