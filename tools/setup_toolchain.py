#!/usr/bin/env python3
"""Restore the verified toolchain on Ubuntu 24.04 x86_64. No root required."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request

assert platform.machine() == 'x86_64', 'Requires x86_64 Linux'
assert sys.platform.startswith('linux'), 'Requires Linux'
assert shutil.which('dpkg-deb'), 'Requires dpkg-deb'
root = Path(os.environ.get('IOS_TOOLCHAIN_ROOT', '/opt/ios-toolchain')).resolve()
root.mkdir(parents=True, exist_ok=True)
lock = json.loads(Path(__file__).with_name('toolchain-lock.json').read_text())

def fetch(item, parent):
    parent.mkdir(parents=True, exist_ok=True)
    dest = parent / item['filename']
    def valid():
        if not dest.is_file():
            return False
        h = hashlib.new(item['algorithm'])
        with dest.open('rb') as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b''):
                h.update(chunk)
        return h.hexdigest() == item['checksum']
    if not valid():
        print('Downloading', item['filename'], flush=True)
        temporary = dest.with_suffix(dest.suffix + '.part')
        with urllib.request.urlopen(item['url'], timeout=120) as response, temporary.open('wb') as out:
            shutil.copyfileobj(response, out)
        temporary.replace(dest)
    assert valid(), f'Checksum failed: {dest.name}'
    return dest

llvmroot = root / 'llvm'
llvmroot.mkdir(exist_ok=True)
for item in lock['packages']:
    archive = fetch(item, root / 'debs')
    subprocess.run(['dpkg-deb', '-x', str(archive), str(llvmroot)], check=True)
archive = fetch(lock['sdk'], root)
sdks = root / 'sdks'
sdks.mkdir(exist_ok=True)
# Only extract an archive whose bytes match the pinned SHA-256 above.
with tarfile.open(archive) as tar:
    for member in tar.getmembers():
        target = (sdks / member.name).resolve()
        assert target.is_relative_to(sdks), 'Unsafe SDK archive path'
    subprocess.run(['tar', '--no-same-owner', '-xJf', str(archive), '-C', str(sdks)], check=True)
(root / 'env.sh').write_text(
    'export IOS_TOOLCHAIN_ROOT=' + shlex.quote(str(root)) + '\n'
    'export IOS_SDK="$IOS_TOOLCHAIN_ROOT/sdks/iPhoneOS16.5.sdk"\n'
    'export PATH="$IOS_TOOLCHAIN_ROOT/llvm/usr/lib/llvm-18/bin:$PATH"\n'
    'export LD_LIBRARY_PATH="$IOS_TOOLCHAIN_ROOT/llvm/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
)
env = dict(os.environ)
env['LD_LIBRARY_PATH'] = str(llvmroot / 'usr/lib/x86_64-linux-gnu') + (':' + env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
subprocess.run([str(llvmroot / 'usr/lib/llvm-18/bin/clang'), '--version'], check=True, env=env)
print('Ready:', root)
