#!/usr/bin/env python3
"""Authorize an exported *public* iPhone SSH key on explicitly selected SSH devices.

Uses existing Mac SSH access. Never reads, copies or changes private keys/passwords.
"""
import argparse
import base64
from pathlib import Path
import shlex
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('public_key', type=Path)
parser.add_argument('hosts', nargs='+', help='SSH targets, e.g. pi@pi5.local')
args = parser.parse_args()
if any(host.startswith('-') for host in args.hosts):
    raise SystemExit('Invalid SSH target')
key = args.public_key.read_text().strip()
parts = key.split()
if len(parts) < 2 or parts[0] != 'ssh-ed25519':
    raise SystemExit('Expected the public Ed25519 key exported by Pi Terminal.')
wire = base64.b64decode(parts[1], validate=True)
if len(wire) != 51 or wire[:19] != b'\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20':
    raise SystemExit('Invalid Ed25519 public key.')
remote = r'''
from pathlib import Path
import os
import sys
key = sys.stdin.read().strip()
fields = key.split()
assert len(fields) >= 2 and fields[0] == 'ssh-ed25519'
folder = Path.home() / '.ssh'
folder.mkdir(mode=0o700, exist_ok=True)
path = folder / 'authorized_keys'
existing = path.read_text() if path.exists() else ''
if not any(line.split()[:2] == fields[:2] for line in existing.splitlines()):
    backup = folder / 'authorized_keys.before-pi-terminal'
    if path.exists():
        try:
            fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            pass
        else:
            with os.fdopen(fd, 'w') as file:
                file.write(existing)
    with path.open('a') as file:
        if existing and not existing.endswith('\n'):
            file.write('\n')
        file.write(key + '\n')
os.chmod(folder, 0o700)
os.chmod(path, 0o600)
assert any(line.split()[:2] == fields[:2] for line in path.read_text().splitlines())
print('iPhone public key authorized; existing keys retained.')
'''
for host in args.hosts:
    name = host
    result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', host,
                             'python3 -c ' + shlex.quote(remote)], input=key, text=True, capture_output=True)
    print(name + ': ' + (result.stdout.strip() if result.returncode == 0 else result.stderr.strip()), flush=True)
    if result.returncode:
        raise SystemExit(result.returncode)
