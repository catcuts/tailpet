#!/usr/bin/env python3
# tailpet tunnel bridge: local listener <-> hub TCP relay
# A-side endpoint: each local connection opens a relay session through the hub
import argparse
import socket
import sys
import threading


def pump(x, y):
    try:
        while True:
            d = x.recv(65536)
            if not d:
                break
            y.sendall(d)
    except Exception:
        pass
    try:
        y.shutdown(socket.SHUT_WR)
    except Exception:
        pass


def handle(local, args):
    try:
        s = socket.create_connection((args.hub, args.relay), timeout=15)
        s.sendall(('A %s %s %s %d\r\n' % (args.admin, args.agent, args.target, args.rport)).encode('ascii'))
        s.settimeout(25)
        buf = b''
        while b'\n' not in buf:
            d = s.recv(256)
            if not d:
                raise IOError('hub closed early')
            buf += d
        if not buf.startswith(b'OK'):
            raise IOError('hub refused: %r' % buf[:80])
        s.settimeout(None)
    except Exception as e:
        sys.stderr.write('relay setup failed: %s\n' % e)
        try:
            local.close()
        except Exception:
            pass
        return
    t1 = threading.Thread(target=pump, args=(local, s), daemon=True)
    t2 = threading.Thread(target=pump, args=(s, local), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    try:
        local.close()
    except Exception:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--hub', required=True, help='hub host')
    ap.add_argument('--relay', type=int, default=80, help='hub relay port')
    ap.add_argument('--admin', required=True, help='hub admin token')
    ap.add_argument('--agent', required=True, help='agent id')
    ap.add_argument('--target', required=True, help='target host reachable from the agent')
    ap.add_argument('--rport', type=int, required=True, help='target port')
    ap.add_argument('--listen', required=True, help='local listen addr, e.g. 127.0.0.1:8080')
    args = ap.parse_args()
    lhost, lport = args.listen.rsplit(':', 1)
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lhost, int(lport)))
    srv.listen(16)
    print('bridge %s:%s -> agent %s -> %s:%d (hub %s:%d)' % (
        lhost, lport, args.agent, args.target, args.rport, args.hub, args.relay), flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, args), daemon=True).start()


if __name__ == '__main__':
    main()
