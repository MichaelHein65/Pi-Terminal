#!/usr/bin/env python3
"""Add only the iPhone's exported IPv4 addresses to a Pi's existing SSH source allowlist."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('network_export', type=Path)
parser.add_argument('ssh_host', help='Existing SSH access, e.g. pi@pi5.local')
parser.add_argument('ssh_user', help='Linux user to authorize')
args = parser.parse_args()
interfaces = json.loads(args.network_export.read_text())
ssh_host, ssh_user = args.ssh_host, args.ssh_user
if ssh_host.startswith('-') or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', ssh_user):
    raise SystemExit('Invalid SSH host or Linux user')
addresses = []
for name, value in interfaces.items():
    ip = ipaddress.IPv4Address(value)
    if name == 'en0' and ip.is_private and not ip.is_loopback:
        addresses.append(str(ip))
    elif name.startswith('utun') and ip in ipaddress.IPv4Network('100.64.0.0/10'):
        addresses.append(str(ip))
if not addresses:
    raise SystemExit('No matching iPhone LAN or Tailscale addresses in the export.')
remote = r'''
from pathlib import Path
import ipaddress
import json
import os
import subprocess
import sys
settings = json.load(sys.stdin)
username = settings['username']
import re
assert re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', username)
addresses = [str(ipaddress.IPv4Address(value)) for value in settings['addresses']]
path = Path('/etc/ssh/sshd_config.d/95-pi-terminal-iphone.conf')
previous = path.read_bytes() if path.exists() else None
content = (previous.decode() if previous is not None else '# Pi Terminal: only the iPhone source addresses; public-key authentication is unchanged.\n')
for address in addresses:
    line = 'AllowUsers ' + username + '@' + address
    if line not in content.splitlines():
        content += ('' if content.endswith('\n') else '\n') + line + '\n'
if previous is not None and previous != content.encode():
    backup = path.with_suffix('.conf.before-pi-terminal')
    try:
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        pass
    else:
        with os.fdopen(fd, 'wb') as file:
            file.write(previous)
path.write_text(content)
os.chmod(path, 0o644)
try:
    subprocess.run(['/usr/sbin/sshd', '-t'], check=True)
    subprocess.run(['systemctl', 'reload', 'ssh'], check=True)
except BaseException:
    if previous is None:
        path.unlink()
    else:
        path.write_bytes(previous)
    subprocess.run(['/usr/sbin/sshd', '-t'], check=True)
    subprocess.run(['systemctl', 'reload', 'ssh'], check=False)
    raise
print('SSH allowlist updated for iPhone only: ' + ', '.join(addresses))
'''
result = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', ssh_host,
                         'sudo -n python3 -c ' + shlex.quote(remote)], input=json.dumps({"username": ssh_user, "addresses": addresses}), text=True)
raise SystemExit(result.returncode)
