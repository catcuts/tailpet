#!/usr/bin/env python3
"""SSH ProxyCommand: pipe stdin/stdout through hub relay to an agent machine (or its LAN).

Reads hub host + admin token from %LOCALAPPDATA%\\tailpet\\{params.json, hub-admin.txt}.
Usage: python ssh-relay.py <agent_id> <target_host> <target_port>
"""
import json
import os
import socket
import sys
import threading

PKG = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'tailpet')

def read_config():
    pj = os.path.join(PKG, 'params.json')
    with open(pj, encoding='utf-8-sig') as f:
        params = json.load(f)
    host = params['server']['host']
    at = open(os.path.join(PKG, 'hub-admin.txt')).read().strip()
    return host, at

def main():
    if len(sys.argv) < 4:
        sys.stderr.write('usage: ssh-relay.py <agent_id> <target_host> <target_port>\n')
        sys.exit(1)
    aid, target, port = sys.argv[1], sys.argv[2], sys.argv[3]
    hub_host, admin = read_config()

    s = socket.create_connection((hub_host, 80), timeout=15)
    s.sendall(('A %s %s %s %s\n' % (admin, aid, target, port)).encode('ascii'))
    s.settimeout(35)
    buf = b''
    while b'\n' not in buf and len(buf) < 256:
        d = s.recv(64)
        if not d:
            sys.stderr.write('hub closed during handshake\n'); sys.exit(1)
        buf += d
    line = buf.split(b'\n', 1)[0].strip()
    if not line.startswith(b'OK'):
        sys.stderr.write('relay refused: %s\n' % line.decode('ascii', 'replace')); sys.exit(1)
    s.settimeout(None)

    def pump(src, dst):
        try:
            while True:
                d = src.recv(65536)
                if not d: break
                dst.sendall(d)
        except Exception:
            pass
        try: dst.shutdown(socket.SHUT_WR)
        except Exception: pass

    t1 = threading.Thread(target=pump, args=(sys.stdin.buffer, s), daemon=True)
    t2 = threading.Thread(target=pump, args=(s, sys.stdout.buffer), daemon=True)
    t1.start(); t2.start(); t1.join(); t2.join()
    s.close()

if __name__ == '__main__':
    main()
