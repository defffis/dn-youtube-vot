#!/usr/bin/env python3
"""Validate this probe's Mach-O metadata and every ad-hoc code-page hash."""
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data)
assert magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 6
assert flags & 1, 'MH_NOUNDEFS missing'
assert 32 + sizeofcmds <= len(data)
version = lambda n: f'{n >> 16}.{n >> 8 & 255}.{n & 255}'
commands = []
deps = []
pos = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, pos)
    assert size >= 8 and pos + size <= 32 + sizeofcmds
    commands.append(cmd)
    if cmd in (0xC, 0xD, 0x80000018, 0x8000001F, 0x80000023):
        nameoff = struct.unpack_from('<I', data, pos + 8)[0]
        name = data[pos + nameoff:pos + size].split(b'\0', 1)[0].decode()
        if cmd == 0xD:
            install_name = name
        else:
            deps.append(name)
    elif cmd == 0x32:
        platform, minimum, sdk = struct.unpack_from('<III', data, pos + 8)
        assert platform == 2 and minimum == 16 << 16
    elif cmd == 0x1D:
        sigoff, sigsize = struct.unpack_from('<II', data, pos + 8)
    pos += size
assert install_name == '@rpath/DNYouTubeVOT.dylib'
assert deps and all(n.startswith(('/usr/lib/', '/System/Library/')) for n in deps)
assert sigoff + sigsize <= len(data)
sigmagic, siglength, count = struct.unpack_from('>III', data, sigoff)
assert sigmagic == 0xFADE0CC0 and siglength <= sigsize
verified = 0
for index in range(count):
    slot, offset = struct.unpack_from('>II', data, sigoff + 12 + index * 8)
    start = sigoff + offset
    cdmagic, length = struct.unpack_from('>II', data, start)
    if cdmagic != 0xFADE0C02:
        continue
    _, _, cdversion, cdflags, hashoff, identoff, nspecial, nslots, codelimit = struct.unpack_from('>9I', data, start)
    hashsize, hashtype, _, pagelog = struct.unpack_from('4B', data, start + 36)
    assert cdflags & 2, 'Not an ad-hoc signature'
    assert hashtype == 2 and hashsize == 32
    pagesize = 1 << pagelog
    assert codelimit == sigoff and nslots == math.ceil(codelimit / pagesize)
    assert hashoff + nslots * hashsize <= length
    for i in range(nslots):
        page = data[i * pagesize:min((i + 1) * pagesize, codelimit)]
        expected = data[start + hashoff + i * hashsize:start + hashoff + (i + 1) * hashsize]
        assert hashlib.sha256(page).digest() == expected, f'Page {i} hash mismatch'
    verified += nslots
assert verified > 0
symbols = subprocess.check_output(['llvm-nm', '--defined-only', '--extern-only', str(path)], text=True)
assert '_MSHookMessageEx' not in symbols
print(json.dumps({
    'file': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
    'format': 'Mach-O 64-bit dynamically linked shared library', 'architecture': 'arm64',
    'platform': 'iOS device', 'minimum_ios': version(minimum), 'sdk_metadata': version(sdk),
    'install_name': install_name, 'dependencies': deps,
    'third_party_tweak_dependencies': [],
    'signature': 'ad-hoc; SHA-256 code-page hashes verified', 'verified_code_pages': verified,
    'compiled_features': ['Objective-C++', 'C++17', 'ARC', 'blocks', 'Foundation', 'UIKit', 'AVFoundation'],
    'device_runtime_tested': False, 'apple_certificate_signed': False
}, indent=2))
