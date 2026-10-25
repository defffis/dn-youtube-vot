#!/usr/bin/env python3
"""Validate this probe's Mach-O metadata and every ad-hoc code-page hash."""
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import uuid

path = Path(sys.argv[1])
data = path.read_bytes()
magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data)
assert magic == 0xFEEDFACF and cpu == 0x0100000C and filetype == 6
assert flags & 1, 'MH_NOUNDEFS missing'
assert 32 + sizeofcmds <= len(data)
version = lambda n: f'{n >> 16}.{n >> 8 & 255}.{n & 255}'
commands = []
deps = []
constructors = []
text_ranges = []
image_uuid = None
pos = 32
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, pos)
    assert size >= 8 and pos + size <= 32 + sizeofcmds
    commands.append(cmd)
    if cmd == 0x1B:
        image_uuid = str(uuid.UUID(bytes=data[pos + 8:pos + 24])).upper()
    elif cmd == 0x19:
        for index in range(struct.unpack_from('<I', data, pos + 64)[0]):
            section = pos + 72 + index * 80
            name = data[section:section + 16].rstrip(b'\0')
            addr, length, offset = struct.unpack_from('<QQI', data, section + 32)
            if name == b'__text':
                text_ranges.append((addr, addr + length))
            if name == b'__mod_init_func':
                assert length and length % 8 == 0
                constructors += list(struct.unpack_from('<' + 'Q' * (length // 8), data, offset))
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
assert install_name == '@rpath/' + path.name
assert image_uuid, 'LC_UUID required for device crash identification'
assert constructors, 'No constructor; injected library would have no bootstrap'
assert all(any(start <= address < end for start, end in text_ranges) for address in constructors)
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
symbols = subprocess.check_output(['llvm-nm', '-a', str(path)], text=True)
assert '_MSHookMessageEx' not in symbols
if 'Probe' in path.name:
    assert '_imp_implementationWithBlock' not in symbols
    assert '_OBJC_CLASS_$_AVPlayer' not in symbols
    assert '_OBJC_CLASS_$_DNVOTClient' not in symbols
print(json.dumps({
    'file': path.name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
    'format': 'Mach-O 64-bit dynamically linked shared library', 'architecture': 'arm64',
    'platform': 'iOS device', 'minimum_ios': version(minimum), 'sdk_metadata': version(sdk),
    'install_name': install_name, 'dependencies': deps,
    'uuid': image_uuid, 'constructors_checked': len(constructors),
    'third_party_tweak_dependencies': [],
    'signature': 'ad-hoc; SHA-256 code-page hashes verified', 'verified_code_pages': verified,
    'compiled_features': ['Objective-C++', 'ARC', 'blocks', 'Foundation', 'UIKit'] + ([] if 'Probe' in path.name else ['C++17', 'AVFoundation']),
    'device_runtime_tested': False, 'apple_certificate_signed': False
}, indent=2))
