#!/usr/bin/env python3
import gzip
import os
import sys

GZIP_MIN_SIZE = 1024
GZIP_MIN_GAIN = 0.9

TYPES = {
    '.html': ('text/html; charset=utf-8', True),
    '.js': ('text/javascript; charset=utf-8', True),
    '.mjs': ('text/javascript; charset=utf-8', True),
    '.css': ('text/css; charset=utf-8', True),
    '.json': ('application/json', True),
    '.svg': ('image/svg+xml', True),
    '.txt': ('text/plain; charset=utf-8', True),
    '.png': ('image/png', False),
    '.ico': ('image/x-icon', False),
    '.woff2': ('font/woff2', False),
}

def fail(msg):
    sys.exit(f'gen_www: {msg}')

def collect(root):
    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            if name.startswith('.'):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            ext = os.path.splitext(name)[1].lower()
            if ext not in TYPES:
                fail(f'{rel}: неизвестный тип файла {ext!r}, добавьте его в TYPES')
            files.append((rel, full, ext))
    return files

def c_string(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def main():
    if len(sys.argv) != 3:
        fail('usage: gen_www.py <www dir> <output.c>')
    root, out_path = sys.argv[1], sys.argv[2]

    arrays = []
    entries = []
    total_src = total_out = 0
    for i, (rel, full, ext) in enumerate(collect(root)):
        with open(full, 'rb') as f:
            data = f.read()
        mime, compressible = TYPES[ext]
        gz = False
        if compressible and len(data) >= GZIP_MIN_SIZE:
            packed = gzip.compress(data, compresslevel=9, mtime=0)
            if len(packed) < len(data) * GZIP_MIN_GAIN:
                data, gz = packed, True
        total_src += os.path.getsize(full)
        total_out += len(data)

        lines = []
        for off in range(0, len(data), 20):
            lines.append('    ' + ', '.join(f'0x{b:02x}' for b in data[off:off + 20]) + ',')
        arrays.append(f'/* {rel} */\nstatic const uint8_t file_{i}[] = {{\n' + '\n'.join(lines) + '\n};\n')
        entries.append(f'    {{ {c_string(rel)}, {c_string(mime)}, file_{i}, sizeof(file_{i}), {"true" if gz else "false"} }},')

    out = [
        '/* Сгенерировано gen_www.py из www/ — не редактировать */',
        '#include "web_files.h"',
        '',
        *arrays,
        'const web_file_t web_files[] = {',
        *entries,
        '};',
        '',
        f'const size_t web_files_count = {len(entries)};',
        '',
    ]
    os.makedirs(os.path.dirname(out_path) or '.', exist_ok=True)
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))
    print(f'gen_www: {len(entries)} files, {total_src} -> {total_out} bytes')

if __name__ == '__main__':
    main()
