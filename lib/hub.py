#!/usr/bin/env python3
# tailpet agent hub - HTTP long-poll command channel (stdlib only, file-swap mode)
# Windows-native: run with any Python 3.8+; state under %ProgramData%\tailpet-hub
import base64
import glob
import hashlib
import json
import os
import secrets
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE = os.path.join(os.environ.get('ProgramData', os.path.expanduser('~')), 'tailpet-hub')
ROOT = os.path.join(BASE, 'agents')
ADMIN_FILE = os.path.join(BASE, 'admin-token.txt')
PORT = 8443
HOLD_MAX = 25
RELAY_PORT = 80
sessions = {}
sess_lock = threading.Lock()


def admin_token():
    try:
        with open(ADMIN_FILE, encoding='utf-8') as f:
            t = f.read().strip()
            if t:
                return t
    except OSError:
        pass
    t = secrets.token_hex(24)
    os.makedirs(BASE, exist_ok=True)
    with open(ADMIN_FILE, 'w', encoding='utf-8') as f:
        f.write(t)
    return t


def agent_dir(aid):
    return os.path.join(ROOT, aid)


def safe_id(aid):
    return bool(aid) and all(c.isalnum() or c in '-_' for c in aid) and '..' not in aid


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def write_json(path, obj):
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(obj, f, ensure_ascii=False)
    os.replace(tmp, path)


def safe_name(fn):
    return bool(fn) and len(fn) <= 80 and all(c.isalnum() or c in '._-' for c in fn) and '..' not in fn


def file_auth(p):
    # admin 直操，或 agent token 校验（不自动注册）
    aid = p.get('id', '')
    if not safe_id(aid):
        return None
    if p.get('admin', '') == ADMIN:
        return aid
    meta = read_json(os.path.join(agent_dir(aid), 'meta.json'))
    if meta and meta.get('token') == p.get('token', ''):
        return aid
    return None


def files_dir(aid):
    d = os.path.join(agent_dir(aid), 'files')
    os.makedirs(d, exist_ok=True)
    return d


def send_bytes(self, body):
    self.send_response(200)
    self.send_header('Content-Type', 'application/octet-stream')
    self.send_header('Content-Length', str(len(body)))
    self.end_headers()
    self.wfile.write(body)


def check_or_register(aid, token):
    if not token or len(token) < 16:
        return False
    d = agent_dir(aid)
    meta = read_json(os.path.join(d, 'meta.json'))
    if meta is None:
        os.makedirs(d, exist_ok=True)
        write_json(os.path.join(d, 'meta.json'), {'token': token, 'firstSeen': int(time.time())})
        return True
    return meta.get('token') == token


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _params(self):
        q = parse_qs(urlparse(self.path).query)
        return {k: v[0] for k, v in q.items()}

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n <= 0 or n > 1024 * 1024:
            return None
        try:
            return json.loads(self.rfile.read(n).decode('utf-8'))
        except Exception:
            return None  # 解析失败才算坏；{}（空对象）是合法心跳

    def do_GET(self):
        with open(os.path.join(BASE, 'get-debug.log'), 'a', encoding='utf-8') as df:
            df.write(time.strftime('%H:%M:%S') + ' GET ' + self.path + chr(10))

        p = self._params()
        aid = p.get('id', '')
        admin = p.get('admin', '')
        if admin == ADMIN:
            if self.path.startswith('/metas'):
                metas = {}
                if os.path.isdir(ROOT):
                    for name in os.listdir(ROOT):
                        m = read_json(os.path.join(ROOT, name, 'meta.json'))
                        if m:
                            metas[name] = m
                return self._json(200, metas)
            if self.path.startswith('/files'):
                aid = file_auth(p)
                if not aid:
                    return self._json(403, {'err': 'forbidden'})
                d = files_dir(aid)
                out = []
                if os.path.isdir(d):
                    for fn in os.listdir(d):
                        tail = fn.rsplit('.', 1)[-1]
                        if fn.endswith('.part') or tail.isdigit():
                            continue
                        fp = os.path.join(d, fn)
                        if os.path.isfile(fp):
                            out.append({'name': fn, 'size': os.path.getsize(fp),
                                        'mtime': int(os.path.getmtime(fp))})
                return self._json(200, out)
            if self.path.startswith('/filechunk'):
                aid = file_auth(p)
                name, seq = p.get('name', ''), p.get('seq', '')
                if not aid or not safe_name(name) or not seq.isdigit():
                    return self._json(403, {'err': 'forbidden'})
                fp = os.path.join(files_dir(aid), name + '.part.' + seq)
                if not os.path.isfile(fp):
                    self.send_response(404)
                    self.end_headers()
                    return
                return send_bytes(self, open(fp, 'rb').read())
            if self.path.startswith('/file?') or self.path == '/file':
                aid = file_auth(p)
                name = p.get('name', '')
                if not aid or not safe_name(name):
                    return self._json(403, {'err': 'forbidden'})
                fp = os.path.join(files_dir(aid), name)
                if not os.path.isfile(fp):
                    return self._json(404, {'err': 'no file'})
                return send_bytes(self, open(fp, 'rb').read())
            if safe_id(aid):
                r = read_json(os.path.join(agent_dir(aid), 'result.json'))
                return self._json(200, {'result': r})
            return self._json(400, {'err': 'bad id'})
        token = p.get('token', '')
        if not safe_id(aid) or not check_or_register(aid, token):
            return self._json(403, {'err': 'forbidden'})
        if self.path.startswith('/filechunk'):
            name, seq = p.get('name', ''), p.get('seq', '')
            if not safe_name(name) or not seq.isdigit():
                return self._json(403, {'err': 'forbidden'})
            fp = os.path.join(files_dir(aid), name + '.part.' + seq)
            if not os.path.isfile(fp):
                self.send_response(404)
                self.end_headers()
                return
            return send_bytes(self, open(fp, 'rb').read())
        cmd_path = os.path.join(agent_dir(aid), 'cmd.b64')
        deadline = time.time() + HOLD_MAX
        cmd64 = ''
        while time.time() < deadline:
            if os.path.exists(cmd_path):
                # a queued file is undelivered (it is removed on fetch) - hand it over now,
                # even if cmdset landed between two polls
                try:
                    with open(cmd_path, encoding='ascii') as f:
                        cmd64 = f.read().strip()
                except OSError:
                    cmd64 = ''
                try:
                    os.remove(cmd_path)
                except OSError:
                    pass
                break
            # pending relay requests ride the same pipe (agent parses __relay lines)
            rq = sorted(glob.glob(os.path.join(agent_dir(aid), 'relayq-*.txt')))
            if rq:
                lines = []
                for fp in rq:
                    try:
                        with open(fp, encoding='ascii') as f:
                            lines.append(f.read().strip())
                    except OSError:
                        pass
                    try:
                        os.remove(fp)
                    except OSError:
                        pass
                lines = [x for x in lines if x]
                if lines:
                    cmd64 = base64.b64encode(('\n'.join(lines) + '\n').encode('ascii')).decode('ascii')
                    break
            time.sleep(0.3)
        # PS2.0-compatible plain-text response (no ConvertFrom-Json on legacy agents)
        body = cmd64.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        path = urlparse(self.path).path
        if path == '/filechunk':
            p = self._params()
            aid = file_auth(p)
            name, seq = p.get('name', ''), p.get('seq', '')
            n = int(self.headers.get('Content-Length') or 0)
            if not aid or not safe_name(name) or not seq.isdigit() or n <= 0 or n > 4 * 1024 * 1024:
                return self._json(403, {'err': 'forbidden'})
            with open(os.path.join(files_dir(aid), name + '.part.' + seq), 'wb') as f:
                f.write(self.rfile.read(n))
            return self._json(200, {'ok': True, 'seq': int(seq)})
        if path == '/filedone':
            p = self._params()
            aid = file_auth(p)
            name = p.get('name', '')
            chunks = p.get('chunks', '')
            if not aid or not safe_name(name) or not chunks.isdigit():
                return self._json(403, {'err': 'forbidden'})
            d = files_dir(aid)
            part = os.path.join(d, name + '.part')
            missing = [i for i in range(1, int(chunks) + 1)
                       if not os.path.isfile(os.path.join(d, name + '.part.' + str(i)))]
            if missing:
                return self._json(400, {'err': 'missing chunks ' + ','.join(map(str, missing[:5]))})
            with open(part, 'wb') as out:
                for i in range(1, int(chunks) + 1):
                    with open(os.path.join(d, name + '.part.' + str(i)), 'rb') as f:
                        out.write(f.read())
            sha = hashlib.sha256(open(part, 'rb').read()).hexdigest()
            final = os.path.join(d, name)
            os.replace(part, final)
            for i in range(1, int(chunks) + 1):
                try:
                    os.remove(os.path.join(d, name + '.part.' + str(i)))
                except OSError:
                    pass
            return self._json(200, {'ok': True, 'sha256': sha, 'size': os.path.getsize(final)})
        if path == '/filedel':
            p = self._params()
            aid = file_auth(p)
            name = p.get('name', '')
            if not aid or not safe_name(name):
                return self._json(403, {'err': 'forbidden'})
            d = files_dir(aid)
            victims = [os.path.join(d, name), os.path.join(d, name + '.part')]
            victims += glob.glob(os.path.join(d, name + '.part.*'))
            for fp in victims:
                try:
                    os.remove(fp)
                except OSError:
                    pass
            return self._json(200, {'ok': True})
        body = self._body()
        if body is None:
            return self._json(400, {'err': 'bad body'})
        p = self._params()
        aid = p.get('id', '')
        admin = p.get('admin', '')
        if admin != ADMIN:
            token = p.get('token', '')
            if not safe_id(aid) or not check_or_register(aid, token):
                return self._json(403, {'err': 'forbidden'})
        d = agent_dir(aid)
        os.makedirs(d, exist_ok=True)
        if path == '/heartbeat':
            meta = read_json(os.path.join(d, 'meta.json')) or {}
            meta['lastSeen'] = int(time.time())
            meta['ip'] = self.client_address[0]
            meta.setdefault('token', body.get('token'))
            if body.get('name'):
                meta['name'] = body.get('name')
            if body.get('pubkey'):
                meta['pubkey'] = body.get('pubkey')
            if body.get('ver'):
                meta['ver'] = body.get('ver')
            write_json(os.path.join(d, 'meta.json'), meta)
            return self._json(200, {'ok': True})
        if path == '/result':
            write_json(os.path.join(d, 'result.json'), {
                'time': int(time.time()),
                'stdout': str(body.get('stdout') or '')[:200000],
                'stderr': str(body.get('stderr') or '')[:200000],
                'exit': body.get('exit'),
            })
            return self._json(200, {'ok': True})
        if path == '/info':
            info = read_json(os.path.join(d, 'info.json')) or {}
            for k, v in body.items():
                info[str(k)[:40]] = str(v)[:200000]
            info['time'] = int(time.time())
            write_json(os.path.join(d, 'info.json'), info)
            return self._json(200, {'ok': True})
        if path == '/cmdset' and admin == ADMIN:
            # store command as plain base64 text (legacy agents cannot parse JSON)
            import base64 as _b64
            c = body.get('c', '')
            with open(os.path.join(d, 'cmd.b64'), 'w') as f:
                f.write(_b64.b64encode(c.encode('utf-8')).decode())
            try:
                os.remove(os.path.join(d, 'result.json'))  # stale result must not satisfy the next exec
            except OSError:
                pass
            return self._json(200, {'ok': True})
        if path == '/purge' and admin == ADMIN:
            import shutil
            shutil.rmtree(d, ignore_errors=True)
            return self._json(200, {'ok': True})
        self._json(404, {'err': 'not found'})


def _splice(a, b):
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
    t1 = threading.Thread(target=pump, args=(a, b), daemon=True)
    t2 = threading.Thread(target=pump, args=(b, a), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    for s in (a, b):
        try:
            s.close()
        except Exception:
            pass


def _relay_conn(c):
    try:
        c.settimeout(30)
        buf = b''
        while b'\n' not in buf and len(buf) < 4096:
            d = c.recv(1024)
            if not d:
                c.close()
                return
            buf += d
        line = buf.split(b'\n', 1)[0].decode('ascii', 'replace').strip()
        parts = line.split()
        if len(parts) == 5 and parts[0] == 'A' and parts[1] == ADMIN:
            aid, host, port = parts[2], parts[3], parts[4]
            if not safe_id(aid) or not port.isdigit() or not (1 <= int(port) <= 65535) \
                    or len(host) > 253 or not all(ch.isalnum() or ch in '-._:' for ch in host):
                c.sendall(b'ERR bad request\n')
                c.close()
                return
            sid = secrets.token_hex(8)
            rq = os.path.join(agent_dir(aid), 'relayq-%s.txt' % sid)
            with open(rq, 'w') as f:
                f.write('__relay %s %s %s\n' % (sid, host, port))
            with sess_lock:
                sessions[sid] = {'a': c, 'aid': aid}
            c.sendall(('OK %s\n' % sid).encode())
            # hold the A side up to 30s for the agent worker to dial in
            for _ in range(60):
                time.sleep(0.5)
                with sess_lock:
                    if sid not in sessions:
                        return  # joined: the splice thread owns both sockets now
            with sess_lock:
                sess = sessions.pop(sid, None)
            if sess is not None:
                try:
                    sess['a'].close()
                except Exception:
                    pass
                try:
                    os.remove(rq)
                except OSError:
                    pass
            return
        if len(parts) == 4 and parts[0] == 'B':
            aid, token, sid = parts[1], parts[2], parts[3]
            meta = read_json(os.path.join(agent_dir(aid), 'meta.json'))
            if not safe_id(aid) or not meta or meta.get('token') != token:
                c.sendall(b'ERR forbidden\n')
                c.close()
                return
            with sess_lock:
                sess = sessions.pop(sid, None)
            if sess is None or sess.get('aid') != aid:
                c.sendall(b'ERR no session\n')
                c.close()
                return
            try:
                os.remove(os.path.join(agent_dir(aid), 'relayq-%s.txt' % sid))
            except OSError:
                pass
            c.sendall(b'OK\n')
            try:
                sess['a'].settimeout(None)
            except Exception:
                pass
            _splice(sess['a'], c)
            return
        c.sendall(b'ERR bad handshake\n')
    except Exception:
        pass
    try:
        c.close()
    except Exception:
        pass


def relay_serve():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('0.0.0.0', RELAY_PORT))
    srv.listen(32)
    print('tailpet relay on 0.0.0.0:%d' % RELAY_PORT, flush=True)
    while True:
        c, _ = srv.accept()
        threading.Thread(target=_relay_conn, args=(c,), daemon=True).start()


ADMIN = admin_token()

if __name__ == '__main__':
    os.makedirs(ROOT, exist_ok=True)
    threading.Thread(target=relay_serve, daemon=True).start()
    print('tailpet hub on 0.0.0.0:%d  state: %s' % (PORT, ROOT), flush=True)
    ThreadingHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
