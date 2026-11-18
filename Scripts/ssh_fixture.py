#!/usr/bin/env python3
"""Loopback-only SSH fixture for simulator integration tests. Requires paramiko."""
import os
import pty
import select
import socket
import struct
import subprocess
import threading
import fcntl
import termios
import paramiko
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

HOST_KEY = paramiko.ECDSAKey.generate()
# Public, deterministic test-only identity. Never authorize this key on a real device.
TEST_RAW_PUBLIC = Ed25519PrivateKey.from_private_bytes(bytes([7]) * 32).public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
TEST_KEY_WIRE = struct.pack('>I', 11) + b'ssh-ed25519' + struct.pack('>I', 32) + TEST_RAW_PUBLIC

class Server(paramiko.ServerInterface):
    def __init__(self):
        self.shell = threading.Event()
        self.size = (24, 80)
        self.master = None
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ('fixture', 'simulator-only') else paramiko.AUTH_FAILED
    def get_allowed_auths(self, username):
        return 'publickey,password'
    def check_auth_none(self, username):
        return paramiko.AUTH_SUCCESSFUL if username == 'tailfixture' else paramiko.AUTH_FAILED
    def check_auth_publickey(self, username, key):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and key.asbytes() == TEST_KEY_WIRE else paramiko.AUTH_FAILED
    def get_banner(self):
        return ('SSH fixture authentication banner', 'en')
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_pty_request(self, channel, term, width, height, pixelwidth, pixelheight, modes):
        self.size = (height, width)
        return True
    def check_channel_window_change_request(self, channel, width, height, pixelwidth, pixelheight):
        self.size = (height, width)
        if self.master is not None:
            fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
        return True
    def check_channel_shell_request(self, channel):
        self.shell.set()
        return True

def serve(sock):
    transport = paramiko.Transport(sock)
    server = Server()
    process = None
    master = None
    try:
        transport.add_server_key(HOST_KEY)
        transport.start_server(server=server)
        channel = transport.accept(20)
        if channel is None or not server.shell.wait(10):
            return
        master, slave = pty.openpty()
        server.master = master
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', *server.size, 0, 0))
        def setup():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        process = subprocess.Popen(['/bin/bash', '--noprofile', '--norc', '-i'], stdin=slave, stdout=slave, stderr=slave,
                                   env={**os.environ, 'TERM': 'xterm-256color', 'PS1': 'fixture$ '}, preexec_fn=setup)
        os.close(slave)
        while transport.is_active() and process.poll() is None:
            ready, _, _ = select.select([master, channel], [], [], 0.2)
            if master in ready:
                data = os.read(master, 32768)
                if not data: break
                channel.sendall(data)
            if channel in ready:
                data = channel.recv(32768)
                if not data: break
                offset = 0
                while offset < len(data):
                    offset += os.write(master, data[offset:])
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()
        if master is not None: os.close(master)
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 22222))
listener.listen()
print('SSH fixture listening on 127.0.0.1:22222', flush=True)
while True:
    sock, _ = listener.accept()
    threading.Thread(target=serve, args=(sock,), daemon=True).start()
