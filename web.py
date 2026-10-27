#!/usr/bin/env python3
"""tailpet web console - local management UI (stdlib only, binds 127.0.0.1).

Usage: python web.py [--port N] [--bg]   (bg mode writes pid/port to web.json)
"""
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request
import webbrowser
import zipfile
import hashlib
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PKG = os.path.dirname(os.path.abspath(__file__))
BS = chr(92)
PARAMS = json.load(open(os.path.join(PKG, 'params.json'), encoding='utf-8-sig'))
HUB = 'http://%s:8443' % PARAMS['server']['host']
CFG_PATH = os.path.join(PKG, 'web.json')
TUNNELS_PATH = os.path.join(PKG, '.tunnels.json')

def admin_token():
    return open(os.path.join(PKG, 'hub-admin.txt'), encoding='utf-8-sig').read().strip()

def load_cfg():
    try:
        return json.load(open(CFG_PATH, encoding='utf-8-sig'))
    except Exception:
        return {}
def save_cfg(c):
    json.dump(c, open(CFG_PATH, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)

def hub_get(path):
    req = urllib.request.Request(HUB + path)
    return json.load(urllib.request.urlopen(req, timeout=15))

def hub_post(path, data=b'{}'):
    req = urllib.request.Request(HUB + path, data=data, method='POST',
                                 headers={'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(req, timeout=15))

def get_metas():
    try:
        return hub_get('/metas?admin=' + admin_token())
    except Exception:
        return None

def agent_by_name(name):
    metas = get_metas()
    if not metas:
        return None
    for aid, m in metas.items():
        if (m.get('name') or '') == name:
            return {'id': aid, 'token': m.get('token', ''), 'meta': m}
    return None

def exec_on_agent(aid, cmd, timeout_sec=0):
    """cmdset + poll result, mirrors Do-AgentExec."""
    send = cmd
    if timeout_sec:
        send = '__timeout %d\n%s' % (timeout_sec, cmd)
    payload = json.dumps({'c': send}, ensure_ascii=False).encode('utf-8')
    hub_post('/cmdset?admin=%s&id=%s' % (admin_token(), aid), payload)
    t0 = int(time.time())
    deadline = t0 + (timeout_sec + 60 if timeout_sec else 130)
    while time.time() < deadline:
        time.sleep(5)
        try:
            r = hub_get('/result?id=%s&admin=%s' % (aid, admin_token())).get('result')
        except Exception:
            continue
        if r and r.get('time') and int(r['time']) >= t0 - 15:
            return {'exit': r.get('exit'), 'stdout': r.get('stdout') or '',
                    'stderr': r.get('stderr') or ''}
    return {'exit': None, 'stdout': '', 'stderr': 'timeout: no result (agent offline or still running)'}

def tunnels_load():
    try:
        return json.load(open(TUNNELS_PATH, encoding='utf-8-sig'))
    except Exception:
        return []
def tunnels_save(t):
    json.dump(t, open(TUNNELS_PATH, 'w', encoding='utf-8'), ensure_ascii=False)
def proc_alive(pid):
    try:
        import ctypes
        k = ctypes.windll.kernel32
        h = k.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        k.CloseHandle(h)
        return True
    except Exception:
        return False

def free_port():
    import socket
    s = socket.socket(); s.bind(('127.0.0.1', 0)); p = s.getsockname()[1]; s.close(); return p

XFER_UP = ('powershell -NoProfile -ExecutionPolicy Bypass -File C:/ProgramData/tailpet/filexfer.ps1 '
           '-Mode up -Hub {hub} -Aid {aid} -Token {tok} -Name {name} -Path "{path}" -DataDir C:/ProgramData/tailpet')
XFER_DN = ('powershell -NoProfile -ExecutionPolicy Bypass -File C:/ProgramData/tailpet/filexfer.ps1 '
           '-Mode dn -Hub {hub} -Aid {aid} -Token {tok} -Name {name} -Path "{path}" -DataDir C:/ProgramData/tailpet')

def file_get(name, rpath, download_dir):
    a = agent_by_name(name)
    if not a:
        return {'ok': False, 'err': 'agent 不存在: %s' % name}
    rname = 'f%d' % int(time.time())
    r = exec_on_agent(a['id'], XFER_UP.format(hub=HUB, aid=a['id'], tok=a['token'],
                                              name=rname, path=rpath), 120)
    if r.get('exit') not in (0,):
        return {'ok': False, 'err': '上传失败: %s' % (r.get('stderr') or r.get('stdout') or ('exit %s' % r.get('exit')))}
    # wait for assembled file
    for _ in range(24):
        try:
            files = hub_get('/files?admin=%s&id=%s' % (admin_token(), a['id']))
            if any(f['name'] == rname for f in files):
                break
        except Exception:
            pass
        time.sleep(5)
    else:
        return {'ok': False, 'err': '上传超时（10 分钟）'}
    data = urllib.request.urlopen(HUB + '/file?admin=%s&id=%s&name=%s' % (admin_token(), a['id'], rname), timeout=300).read()
    os.makedirs(download_dir, exist_ok=True)
    local = os.path.join(download_dir, os.path.basename(rpath.replace('\\', '/').split('/')[-1]))
    open(local, 'wb').write(data)
    try:
        hub_post('/filedel?admin=%s&id=%s&name=%s' % (admin_token(), a['id'], rname))
    except Exception:
        pass
    return {'ok': True, 'local': local, 'size': len(data)}

def file_put(name, data, rpath, origname=''):
    a = agent_by_name(name)
    if not a:
        return {'ok': False, 'err': 'agent 不存在: %s' % name}
    rname = 'f%d' % int(time.time())
    CH = 262144
    seq = 1
    for off in range(0, len(data), CH):
        chunk = data[off:off + CH]
        req = urllib.request.Request(
            HUB + '/filechunk?admin=%s&id=%s&name=%s&seq=%d' % (admin_token(), a['id'], rname, seq),
            data=chunk, method='POST', headers={'Content-Type': 'application/octet-stream'})
        urllib.request.urlopen(req, timeout=180).read()
        seq += 1
    if not rpath or rpath.startswith('spool'):
        base = origname or rname
        rpath = 'C:/ProgramData/tailpet/spool/' + base.replace(BS, '/').split('/')[-1]
    r = exec_on_agent(a['id'], XFER_DN.format(hub=HUB, aid=a['id'], tok=a['token'],
                                              name=rname, path=rpath), 120)
    try:
        hub_post('/filedel?admin=%s&id=%s&name=%s' % (admin_token(), a['id'], rname))
    except Exception:
        pass
    if r.get('exit') == 0:
        return {'ok': True, 'remote': rpath}
    return {'ok': False, 'err': '下发失败: %s' % (r.get('stderr') or r.get('stdout') or ('exit %s' % r.get('exit')))}

def agent_add(name):
    if not name or re.search(r'\s', name):
        return {'ok': False, 'err': '名称不能为空或含空白'}
    # idempotent: reuse id/token on same name
    aid, tok = '', ''
    metas = get_metas() or {}
    for k, m in metas.items():
        if (m.get('name') or '') == name:
            aid, tok = k, m.get('token', '')
            reused = True
            break
    reused = bool(aid)
    if not aid:
        aid = 'a' + secrets.token_hex(6)
        tok = secrets.token_urlsafe(24).replace('-', '').replace('_', '')[:32]
    tpl = open(os.path.join(PKG, 'bootstrap', 'agent-v2.ps1.template'), encoding='utf-8-sig').read()
    ps1 = (tpl.replace('{{HUB_URL}}', HUB).replace('{{AGENT_ID}}', aid)
              .replace('{{TOKEN}}', tok).replace('{{NAME}}', name))
    out_dir = os.path.join(PKG, 'out')
    os.makedirs(out_dir, exist_ok=True)
    zp = os.path.join(out_dir, 'Agent-Bootstrap-%s.zip' % name)
    cache = os.path.join(PKG, 'bootstrap', 'cache')
    with zipfile.ZipFile(zp, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(PKG, 'bootstrap', 'Add-Agent-V2.bat'), 'Add-Agent.bat')
        z.writestr('agent.ps1', b'\xef\xbb\xbf' + ps1.replace('\n', '\r\n').encode('utf-8'))
        for extra in ('OpenSSH-Win64.zip', 'plink.exe'):
            fp = os.path.join(cache, extra)
            if os.path.exists(fp):
                z.write(fp, extra)
    return {'ok': True, 'zip': zp, 'aid': aid, 'reused': reused}

def spawn_tunnel(name, rport, lport, target):
    a = agent_by_name(name)
    if not a:
        return {'ok': False, 'err': 'agent 不存在: %s' % name}
    t = target or '127.0.0.1'
    key = 'agent|%s|%s|%s' % (a['id'], t, rport)
    tunnels = tunnels_load()
    if not lport:
        for x in tunnels:
            if x.get('key') == key and proc_alive(x.get('pid', 0)):
                return {'ok': True, 'port': x['port'], 'reused': True,
                        'url': 'http://127.0.0.1:%s' % x['port']}
        lport = free_port()
    CREATE_NO_WINDOW = 0x08000000
    p = subprocess.Popen([sys.executable, os.path.join(PKG, 'bridge.py'),
                          '--hub', PARAMS['server']['host'], '--relay', '80',
                          '--admin', admin_token(), '--agent', a['id'],
                          '--target', t, '--rport', str(rport),
                          '--listen', '127.0.0.1:%s' % lport],
                         creationflags=CREATE_NO_WINDOW)
    # wait until listening
    import socket as _s
    for _ in range(30):
        time.sleep(0.5)
        try:
            c = _s.create_connection(('127.0.0.1', int(lport)), timeout=1); c.close(); break
        except Exception:
            pass
    else:
        return {'ok': False, 'err': 'bridge 启动失败'}
    tunnels.append({'port': str(lport), 'pid': p.pid,
                    'target': '%s -> %s:%s' % (name, t, rport), 'via': 'hub 中继',
                    'key': key, 'started': time.strftime('%m-%d %H:%M')})
    tunnels_save(tunnels)
    return {'ok': True, 'port': lport, 'url': 'http://127.0.0.1:%s' % lport}

def tunnel_stop(lport):
    tunnels = tunnels_load()
    kept, killed = [], []
    for x in tunnels:
        if str(x.get('port')) == str(lport) or not lport:
            try:
                subprocess.run(['taskkill', '/F', '/T', '/PID', str(x['pid'])],
                               capture_output=True, creationflags=0x08000000)
                killed.append(x['port'])
            except Exception:
                pass
        else:
            kept.append(x)
    tunnels_save(kept)
    return {'ok': True, 'stopped': killed}

def make_state():
    metas = get_metas()
    now = int(time.time())
    agents = []
    hub_ok = metas is not None
    if metas:
        for aid, m in metas.items():
            ls = m.get('lastSeen') or 0
            agents.append({'id': aid, 'name': m.get('name') or aid,
                           'online': now - ls < 90, 'ver': m.get('ver') or '-',
                           'seen': time.strftime('%m-%d %H:%M', time.localtime(ls)) if ls else '-',
                           'ip': m.get('ip') or ''})
    agents.sort(key=lambda x: (0 if x['online'] else 1, x['name']))
    tunnels = []
    for x in tunnels_load():
        alive = proc_alive(x.get('pid', 0))
        tunnels.append({'port': x['port'], 'target': x['target'], 'started': x.get('started', ''),
                        'via': x.get('via', ''), 'alive': alive})
    cfg = load_cfg()
    return {'hub_ok': hub_ok, 'agents': agents, 'tunnels': tunnels,
            'config': {'refresh': int(cfg.get('refresh', 30)),
                       'download_dir': cfg.get('download_dir') or
                           os.path.join(os.path.expanduser('~'), 'Downloads')}}

PAGE = r'''<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>tailpet 控制台</title>
<style>
:root{--pri:#2563eb;--pri-h:#1d4ed8;--pri-soft:#eff6ff;--ok:#059669;--ok-bg:#ecfdf5;--bad:#e11d48;
--bad-bg:#fff1f2;--txt:#0f172a;--sub:#64748b;--line:#e2e8f0;--bg:#f8fafc;--card:#fff}
*{box-sizing:border-box}
body{font-family:-apple-system,"Segoe UI","Microsoft YaHei",system-ui,sans-serif;margin:0;background:var(--bg);color:var(--txt);font-size:14px}
header{position:sticky;top:0;z-index:5;background:rgba(255,255,255,.86);backdrop-filter:blur(8px);
border-bottom:1px solid var(--line);padding:12px 22px;display:flex;gap:18px;align-items:center;flex-wrap:wrap}
.logo{display:flex;align-items:center;gap:9px;font-weight:700;font-size:16px}
.logo .dot{width:10px;height:10px;border-radius:50%;background:var(--pri);box-shadow:0 0 0 4px var(--pri-soft)}
.hstat{font-size:13px;color:var(--sub)}.hstat b{color:var(--txt)}
.spacer{flex:1}
.card{background:var(--card);margin:16px 22px;border:1px solid var(--line);border-radius:14px;
box-shadow:0 1px 2px rgba(15,23,42,.04);padding:16px 18px}
.bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:12px}
/* 工具栏等高对齐：所有子元素统一 28px 高，顶/底间距一致（曾因高度不一 + 中线对齐显得偏上） */
.bar>*{align-self:center}
.bar h3,.bar .cnt,.bar .hint,.bar .hstat{line-height:28px}
.bar button,.bar input,.bar select{height:28px;padding:0 11px;line-height:26px}
/* 光学补偿：边框顶边比标题字形顶边高 ~7px（字形在 28px 行框内居中有 leading）——控件下移对齐视觉顶边 */
.bar button,.bar input,.bar select{position:relative;top:4px}
.bar h3{margin:0;font-size:13.5px;display:flex;align-items:center;gap:8px;font-weight:650}
.bar .m{font-size:15px}
.bar .cnt{color:var(--sub);font-weight:400;font-size:12px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{padding:9px 10px;text-align:left}
th{color:var(--sub);font-weight:550;font-size:12px;border-bottom:1px solid var(--line)}
td{border-bottom:1px solid #f1f5f9}
tbody tr{transition:background .12s}
tbody tr:hover{background:#f8fafc}
tbody tr:last-child td{border-bottom:none}
button{border:1px solid var(--line);background:#fff;border-radius:9px;padding:5px 11px;cursor:pointer;
font-size:12.5px;color:var(--txt);transition:all .13s;font-family:inherit}
button:hover{border-color:#cbd5e1;background:#f8fafc;transform:translateY(-1px)}
button:active{transform:none}
button.pri{background:var(--pri);color:#fff;border-color:var(--pri);box-shadow:0 1px 2px rgba(37,99,235,.28)}
button.pri:hover{background:var(--pri-h)}
button.ghost{border-color:transparent;background:#f1f5f9;color:#334155}
button.ghost:hover{background:#e2e8f0}
button.warn{color:var(--bad);border-color:#fecdd3}
button.warn:hover{background:var(--bad-bg)}
input,select{border:1px solid var(--line);border-radius:9px;padding:6px 10px;font-size:12.5px;background:#fff;
color:var(--txt);outline:none;transition:border .13s,box-shadow .13s;font-family:inherit}
input:focus,select:focus{border-color:var(--pri);box-shadow:0 0 0 3px var(--pri-soft)}
pre{background:#0f172a;color:#e2e8f0;padding:13px 15px;border-radius:11px;font-size:12.5px;line-height:1.55;
max-height:280px;overflow:auto;white-space:pre-wrap;font-family:"Cascadia Code",Consolas,monospace;margin:10px 0 0}
.badge{display:inline-flex;align-items:center;gap:6px;padding:3px 10px;border-radius:999px;font-size:12px;font-weight:500}
.badge.on{background:var(--ok-bg);color:var(--ok)}
.badge.off{background:#f1f5f9;color:var(--sub)}
.badge .d{width:7px;height:7px;border-radius:50%}
.badge.on .d{background:var(--ok);box-shadow:0 0 0 3px #d1fae5}
.badge.off .d{background:#94a3b8}
.ver{display:inline-block;min-width:30px;text-align:center;background:#f1f5f9;border-radius:6px;padding:1px 7px;
font-size:11.5px;color:var(--sub);font-weight:600}
.ver.v2{background:var(--pri-soft);color:var(--pri)}
.nmrow{display:inline-flex;align-items:center;gap:4px}
.cp{border:none;background:none;padding:2px 4px;font-size:12px;color:#94a3b8;cursor:pointer;vertical-align:middle}
.cp:hover{color:var(--pri);background:var(--pri-soft);border-radius:5px}
.cp.ok{color:var(--ok);background:var(--ok-bg);border-radius:5px}
input[type=checkbox]{accent-color:var(--pri);width:15px;height:15px;cursor:pointer}
button.danger{background:var(--bad);border-color:var(--bad);color:#fff;box-shadow:0 1px 2px rgba(225,29,72,.25)}
button.danger:hover{background:#be123c}
#askModal .mbox{max-width:420px}
#askMsg{white-space:pre-line;line-height:1.65;font-size:13px;color:#334155;margin:0 0 14px;
max-height:46vh;overflow:auto;word-break:break-all}
.row{display:flex;gap:9px;align-items:center;flex-wrap:wrap;margin:8px 0}
.hint{font-size:11.5px;color:#94a3b8}
.kv{font-size:12.5px;color:var(--sub)}
.sep{height:1px;background:var(--line);margin:12px 0}
.nm{cursor:text;padding:2px 5px;border-radius:6px;border:1px solid transparent;transition:all .12s;font-weight:550}
.nm:hover{border-color:#cbd5e1;background:#f8fafc}
.nm.editing{border-color:var(--pri);background:#fff;box-shadow:0 0 0 3px var(--pri-soft);font-weight:400}
#toast{position:fixed;bottom:22px;right:22px;background:#0f172a;color:#fff;padding:11px 18px;border-radius:12px;
font-size:13px;display:none;z-index:99;box-shadow:0 8px 24px rgba(15,23,42,.28);max-width:60vw}
.modal{position:fixed;inset:0;background:rgba(15,23,42,.45);z-index:50;display:none;align-items:center;
justify-content:center;padding:20px}
.modal.show{display:flex}
.mbox{background:#fff;border-radius:16px;box-shadow:0 24px 64px rgba(15,23,42,.3);width:100%;max-width:760px;
max-height:88vh;display:flex;flex-direction:column;overflow:hidden}
.mhead{display:flex;align-items:center;gap:10px;padding:14px 18px;border-bottom:1px solid var(--line);font-weight:650}
.mhead .x{margin-left:auto;border:none;background:none;font-size:17px;color:var(--sub);padding:2px 8px}
.mbody{padding:16px 18px;overflow:auto}
.hlist{display:flex;flex-direction:column;gap:10px}
.hitem{border:1px solid var(--line);border-radius:10px;padding:9px 12px}
.hitem .hcmd{font-family:"Cascadia Code",Consolas,monospace;font-size:12px;color:var(--pri);word-break:break-all}
.hitem .hmeta{font-size:11px;color:#94a3b8;margin-top:3px}
.hitem pre{margin:8px 0 0;max-height:170px}
footer{margin:8px 22px 22px;color:#94a3b8;font-size:11.5px;text-align:center}
</style></head><body>
<header>
 <div class="logo"><span class="dot"></span>tailpet 控制台</div>
 <span class="hstat" id="hubstat">连接中…</span>
 <span class="hstat" id="cnt"></span>
 <span class="spacer"></span>
 <span class="hstat">自动刷新间隔</span>
 <span style="display:inline-flex;align-items:center;gap:4px"><input id="rf" style="width:52px"><span class="hstat">秒</span></span>
 <span class="hint">改后下一轮生效</span>
 <button class="ghost" onclick="refresh()">立即刷新</button>
</header>

<div class="card"><div class="bar">
 <h3><span class="m">🖥️</span>机器管理</h3><span class="cnt" id="agCnt"></span><span class="spacer"></span>
 <select id="agStat"><option value="">全部状态</option><option value="1">在线</option><option value="0">离线</option></select>
 <input id="agFilter" placeholder="按名称过滤…" style="width:150px">
 <button class="pri" onclick="addAgent()">＋ 新增机器</button>
 <button class="warn" id="batchRm" style="display:none" onclick="rmAgents()">删除所选</button>
</div>
<div style="overflow-x:auto">
<table id="agents"><thead><tr><th style="width:30px"><input type="checkbox" id="ckAllA" onchange="toggleAllA(this.checked)"></th><th>名称（点击改名）</th><th>状态</th><th>版本</th><th>最后心跳</th><th>出口 IP</th><th>操作</th></tr></thead><tbody></tbody></table>
</div></div>

<div class="card"><div class="bar">
 <h3><span class="m">🔗</span>隧道管理</h3><span class="cnt" id="tCnt"></span><span class="spacer"></span>
 <input id="tFilter" placeholder="过滤端口/目标…" style="width:150px">
 <button class="pri" onclick="openTunModal()">＋ 新建隧道</button>
 <button class="warn" id="batchStop" style="display:none" onclick="stopSelTunnels()">停止所选</button>
 <button class="warn" id="stopAllBtn" onclick="stopAllTunnels()">全部停止</button>
</div>
<table id="tunnels"><thead><tr><th style="width:30px"><input type="checkbox" id="ckAllT" onchange="toggleAllT(this.checked)"></th><th>本地端口</th><th>机器名称</th><th>中转</th><th>目标</th><th>状态</th><th>建立时间</th><th>操作</th></tr></thead><tbody></tbody></table>
</div>

<div class="modal" id="fileModal" onclick="if(event.target===this)closeModals()"><div class="mbox" style="max-width:560px">
 <div class="mhead"><span class="m">📁</span>传输文件 · <span id="fmName" style="color:var(--pri)"></span>
  <button class="x" onclick="closeModals()">✕</button></div>
 <div class="mbody">
<div class="row">⬇️ 取回　远端路径 <input id="fPath" style="flex:1;min-width:220px" placeholder="C:\ProgramData\tailpet\spool\out.log">
 <button class="pri" onclick="doGet()">取回</button></div>
<div class="row">　目录　<input id="dlDir" style="flex:1;min-width:200px"> <button class="ghost" onclick="saveCfg2()">保存</button></div>
<div class="sep"></div>
<div class="row">⬆️ 推送　<input type="file" id="fUp"> 目标 <input id="fRemote" placeholder="spool\同名" style="width:170px">
 <button class="pri" onclick="doPut()">推送</button></div>
<pre id="fOut">（传输记录）</pre>
 </div>
</div></div>

<div class="modal" id="cmdModal" onclick="if(event.target===this)closeModals()"><div class="mbox">
 <div class="mhead"><span class="m">⌨️</span>执行命令 · <span id="cmName" style="color:var(--pri)"></span>
  <button class="x" onclick="closeModals()">✕</button></div>
 <div class="mbody">
  <div class="row"><input id="cmCmd" placeholder="输入命令，回车执行…" style="flex:1"
    onkeydown="if(event.key==='Enter')runInModal()">
   超时 <input id="cmTmo" value="120" style="width:52px"> s
   <button class="pri" onclick="runInModal()">执行</button></div>
  <div class="hint" style="margin:2px 0 10px">历史保留最近 30 条（本浏览器）；输出按执行时间倒序</div>
  <div class="hlist" id="cmHist"></div>
 </div>
</div></div>

<div class="modal" id="tunModal" onclick="if(event.target===this)closeModals()"><div class="mbox" style="max-width:430px">
 <div class="mhead"><span class="m">🔗</span>新建隧道<button class="x" onclick="closeModals()">✕</button></div>
 <div class="mbody">
  <div class="row">远端机器 <select id="tAgent" style="flex:1"></select></div>
  <div class="row">远端端口 <input id="tPort" value="80" style="width:70px">
   本地端口 <input id="tLport" placeholder="自动" style="width:70px"></div>
  <div class="row">目标 IP <input id="tTarget" placeholder="该机本机（127.0.0.1）" style="flex:1"></div>
  <div class="row" style="justify-content:flex-end"><button onclick="closeModals()">取消</button>
   <button class="pri" onclick="createTun()">创建并打开</button></div>
 </div>
</div></div>

<div class="modal" id="askModal"><div class="mbox">
 <div class="mhead" id="askTitle">确认</div>
 <div class="mbody">
  <div id="askMsg"></div>
  <div class="row" id="askInputRow" style="display:none"><input id="askInput" style="flex:1"></div>
  <div class="row" style="justify-content:flex-end;gap:8px">
   <button onclick="askResolve(false)">取消</button>
   <button class="pri" id="askOkBtn" onclick="askResolve(true)">确认</button>
  </div>
 </div>
</div></div>

<div id="toast"></div>
<footer>tailpet 控制台 · 仅本机访问 · 危险操作需确认</footer>
<script>
let AG=[],TUN=[],CFG={refresh:30},CM={name:'',aid:''};
function toast(m,ms){const t=document.getElementById('toast');t.textContent=m;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(()=>t.style.display='none',ms||2600)}
async function api(p,body){const r=await fetch(p,body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:undefined);return r.json()}
function esc(s){return String(s).replace(/'/g,"\\'")}
function escHtml(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;')}
let SELA=new Set(),SELT=new Set();
function selA(n,v){v?SELA.add(n):SELA.delete(n);updateSelUI()}
function selT(p,v){v?SELT.add(String(p)):SELT.delete(String(p));updateSelUI()}
function toggleAllA(v){agFiltered().forEach(a=>v?SELA.add(a.name):SELA.delete(a.name));renderAgents();updateSelUI()}
function toggleAllT(v){tFiltered().forEach(t=>v?SELT.add(String(t.port)):SELT.delete(String(t.port)));renderTunnels();updateSelUI()}
function updateSelUI(){
 const bRm=document.getElementById('batchRm'),bSt=document.getElementById('batchStop'),bAll=document.getElementById('stopAllBtn');
 bRm.style.display=SELA.size?'':'none';bRm.textContent=`删除所选 (${SELA.size})`;
 bSt.style.display=SELT.size?'':'none';bSt.textContent=`停止所选 (${SELT.size})`;
 if(bAll)bAll.style.display=SELT.size?'none':''}
async function rmAgents(){const names=[...SELA];if(!names.length)return;
 if(!await ask({title:`删除 ${names.length} 台机器`,danger:true,msg:`确认删除所选 ${names.length} 台机器？\n\n${names.join('、')}\n\n注意：仅删除 hub 注册（agent 若仍在运行会自动重新注册；彻底移除需在目标机卸载）。`}))return;
 for(const n of names){await api('/api/agent-rm',{name:n})}
 SELA.clear();toast(`已删除 ${names.length} 台`);refresh()}
async function stopSelTunnels(){const ps=[...SELT];if(!ps.length)return;
 if(!await ask({title:`停止 ${ps.length} 条隧道`,danger:true,msg:`确认停止所选 ${ps.length} 条隧道？\n\n端口：${ps.join('、')}`}))return;
 for(const p of ps){await api('/api/tunnel-stop',{lport:p})}
 SELT.clear();toast(`已停止 ${ps.length} 条`);refresh()}
function copyName(n,btn){const ok=()=>{if(!btn)return;btn.textContent='✓';btn.classList.add('ok');
 clearTimeout(btn._t);btn._t=setTimeout(()=>{btn.textContent='⧉';btn.classList.remove('ok')},2000)};
 (navigator.clipboard?navigator.clipboard.writeText(n):Promise.reject()).then(ok)
 .catch(()=>{const ta=document.createElement('textarea');ta.value=n;document.body.appendChild(ta);
 ta.select();try{document.execCommand('copy');ok()}catch(e){toast('复制失败')}ta.remove()})}

async function refresh(){
 try{const s=await api('/api/state');AG=s.agents;TUN=s.tunnels;CFG=s.config;
  document.getElementById('hubstat').innerHTML=s.hub_ok?'<b style="color:var(--ok)">● hub 在线</b>':'<b style="color:var(--bad)">● hub 不可达</b>';
  document.getElementById('cnt').textContent=`站点 ${s.agents.length} · 在线 ${s.agents.filter(a=>a.online).length}`;
  if(document.activeElement.id!=='rf')document.getElementById('rf').value=s.config.refresh;
  if(document.activeElement.id!=='dlDir')document.getElementById('dlDir').value=s.config.download_dir;
  const an=new Set(AG.map(a=>a.name));SELA=new Set([...SELA].filter(x=>an.has(x)));
  const tn=new Set(TUN.map(t=>String(t.port)));SELT=new Set([...SELT].filter(x=>tn.has(x)));
  renderAgents();renderTunnels();fillAgentSel();updateSelUI();
 }catch(e){document.getElementById('hubstat').innerHTML='<b style="color:var(--bad)">● 控制台服务异常</b>'}
}
function agFiltered(){const q=(document.getElementById('agFilter').value||'').toLowerCase(),st=document.getElementById('agStat').value;
 return AG.filter(a=>(!q||a.name.toLowerCase().includes(q))&&(st===''||String(+a.online)===st))}
function renderAgents(){const list=agFiltered();
 document.getElementById('agCnt').textContent=`${list.length}/${AG.length} 台`;
 const tb=document.querySelector('#agents tbody');tb.innerHTML=list.length?'':'<tr><td colspan="6" class="hint">（无匹配机器）</td></tr>';
 for(const a of list){const tr=document.createElement('tr');
  tr.innerHTML=`<td><input type="checkbox" ${SELA.has(a.name)?'checked':''} onchange="selA('${esc(a.name)}',this.checked)"></td>
  <td><span class="nmrow"><span class="nm" onclick="editNm(this,'${esc(a.name)}','${a.id}')" title="点击改名">${escHtml(a.name)}</span><button class="cp" title="复制名称" onclick="copyName('${esc(a.name)}',this)">⧉</button></span></td>
  <td><span class="badge ${a.online?'on':'off'}"><span class="d"></span>${a.online?'在线':'离线'}</span></td>
  <td><span class="ver ${a.ver!=='-'?'v2':''}">${a.ver}</span></td><td class="kv">${a.seen}</td><td class="kv">${a.ip}</td>
  <td style="white-space:nowrap"><button onclick="openCmd('${esc(a.name)}','${a.id}')">执行命令</button>
   <button onclick="openFile('${esc(a.name)}')">传输文件</button>
   <button onclick="openTunModal('${esc(a.name)}')">新建隧道</button>
   <button onclick="genPkgFor('${esc(a.name)}')">生成安装包</button>
   <button class="warn" onclick="rmAgent('${esc(a.name)}')">删除</button></td>`;tb.appendChild(tr)}}
function tFiltered(){const q=(document.getElementById('tFilter').value||'').toLowerCase();
 return TUN.filter(t=>!q||String(t.port).includes(q)||t.target.toLowerCase().includes(q))}
function renderTunnels(){const list=tFiltered();
 document.getElementById('tCnt').textContent=`${list.length}/${TUN.length} 条`;
 const tb=document.querySelector('#tunnels tbody');tb.innerHTML=list.length?'':'<tr><td colspan="7" class="hint">（无匹配隧道）</td></tr>';
 for(const t of list){const tr=document.createElement('tr');
  const seg=t.target.split(' -> ');const hasRelay=seg.length>1;
  const machine=hasRelay?seg[0]:'',tgt=hasRelay?seg[1]:t.target;
  tr.innerHTML=`<td><input type="checkbox" ${SELT.has(String(t.port))?'checked':''} onchange="selT('${t.port}',this.checked)"></td>
  <td><b>${t.port}</b></td><td>${machine?escHtml(machine):'<span class="hint">—</span>'}</td><td>${t.via?escHtml(t.via):'<span class="hint">—</span>'}</td><td>${escHtml(tgt)}</td>
  <td><span class="badge ${t.alive?'on':'off'}"><span class="d"></span>${t.alive?'运行中':'已失联'}</span></td>
  <td class="kv">${t.started}</td><td><button class="warn" onclick="stopTunnel(${t.port})">停止</button></td>`;tb.appendChild(tr)}}
function fillAgentSel(keep){const sel=document.getElementById('tAgent');const k=keep||sel.value;sel.innerHTML='';
 for(const a of AG){const o=document.createElement('option');o.value=a.name;o.textContent=a.name;sel.appendChild(o)}
 if(k)sel.value=k}

function editNm(span,name,aid){
 if(span.dataset.editing)return;span.dataset.editing='1';
 const inp=document.createElement('input');inp.value=name;inp.className='nm editing';inp.style.width=Math.max(90,name.length*13)+'px';
 span.replaceWith(inp);inp.focus();inp.select();
 let done=false;const fin=async save=>{if(done)return;done=true;
  const nv=inp.value.trim();
  if(!save||!nv||nv===name){inp.replaceWith(span);delete span.dataset.editing;return}
  const r=await api('/api/agent-rename',{name,new:nv});
  if(r.ok){toast('已改名: '+nv);refresh()}else{toast('改名失败: '+r.err);inp.replaceWith(span)}};
 inp.onblur=()=>fin(true);
 inp.onkeydown=e=>{if(e.key==='Enter')inp.blur();if(e.key==='Escape')fin(false)}}

function histKey(){return 'tph_'+CM.aid}
function loadHist(){try{return JSON.parse(localStorage.getItem(histKey())||'[]')}catch(e){return[]}}
function saveHist(h){localStorage.setItem(histKey(),JSON.stringify(h.slice(0,30)))}
function renderHist(){const el=document.getElementById('cmHist');const h=loadHist();
 el.innerHTML=h.length?'':'<div class="hint">（暂无历史，输入命令开始）</div>';
 for(const x of h){const d=document.createElement('div');d.className='hitem';
  d.innerHTML=`<div class="hcmd">$ ${escHtml(x.cmd)}</div><div class="hmeta">${x.t} · exit ${x.exit}</div>
  <pre>${escHtml(x.out||'(无输出)')}</pre>`;el.prepend(d)}}
function openCmd(name,aid){CM={name,aid};document.getElementById('cmName').textContent=name;
 document.getElementById('cmdModal').classList.add('show');renderHist();
 setTimeout(()=>document.getElementById('cmCmd').focus(),50)}
async function runInModal(){const c=document.getElementById('cmCmd').value.trim(),t=+document.getElementById('cmTmo').value||120;
 if(!c)return;if(!await ask({title:'执行命令',msg:`确认在【${CM.name}】执行命令？\n\n${c}\n\n超时 ${t} 秒`}))return;
 document.getElementById('cmCmd').value='';
 const h=loadHist();h.push({t:new Date().toLocaleString(),cmd:c,exit:'…',out:'执行中…'});saveHist(h);renderHist();
 const r=await api('/api/exec',{name:CM.name,cmd:c,timeout:t});
 const h2=loadHist();h2[h2.length-1]={t:new Date().toLocaleString(),cmd:c,exit:r.exit,
  out:(r.stdout||'')+(r.stderr?'\n[stderr] '+r.stderr:'')};saveHist(h2);renderHist()}
function openFile(n){document.getElementById('fmName').textContent=n;
 document.getElementById('fileModal').classList.add('show')}
async function doGet(){const n=document.getElementById('fmName').textContent,p=document.getElementById('fPath').value.trim();
 if(!p)return toast('请填远端路径');toast('⏳ 取回中…（大文件耐心等待）',30000);
 const r=await api('/api/file-get',{name:n,rpath:p});
 toast(r.ok?`已取回: ${r.local}（${r.size} bytes）`:'失败: '+r.err,5000);
 document.getElementById('fOut').textContent+=`\n${r.ok?'✅':'❌'} ${p} → ${r.local||r.err}`}
async function doPut(){const n=document.getElementById('fmName').textContent,f=document.getElementById('fUp').files[0];
 if(!f)return toast('请选择文件');const rp=document.getElementById('fRemote').value.trim();
 if(!await ask({title:'推送文件',msg:`确认推送到【${n}】？\n\n${f.name} (${f.size} bytes) → ${rp||'spool\\'+f.name}`}))return;
 toast('⏳ 推送中…',30000);
 const buf=await f.arrayBuffer();
 const r=await fetch('/api/file-put',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Name':encodeURIComponent(n),'X-Path':encodeURIComponent(rp||('spool\\\\'+f.name)),'X-File':encodeURIComponent(f.name)},body:buf}).then(x=>x.json());
 toast(r.ok?'推送完成: '+r.remote:'失败: '+r.err,4000);
 document.getElementById('fOut').textContent+=`\n${r.ok?'✅':'❌'} ${f.name} → ${r.remote||r.err}`}

function openTunModal(name){fillAgentSel(name||null);
 if(name)document.getElementById('tAgent').value=name;
 document.getElementById('tunModal').classList.add('show')}
async function createTun(){const n=tAgent.value,p=+tPort.value||80,l=tLport.value.trim(),t=tTarget.value.trim();
 if(!await ask({title:'新建隧道',msg:`确认新建隧道？\n\n${n} ${t||'本机'}:${p} → 本机 ${l||'自动'}`}))return;
 const r=await api('/api/tunnel',{name:n,rport:p,lport:l,target:t});
 if(r.ok){closeModals();toast(`隧道已建立: ${r.url}`);window.open(r.url,'_blank');refresh()}else toast('失败: '+r.err)}
async function stopTunnel(p){if(!await ask({title:'停止隧道',danger:true,msg:`确认停止隧道 ${p}？`}))return;const r=await api('/api/tunnel-stop',{lport:p});toast('已停止: '+r.stopped.join(', '));refresh()}
async function stopAllTunnels(){if(!TUN.length)return toast('无隧道');if(!await ask({title:'全部停止',danger:true,msg:`确认停止全部 ${TUN.length} 条隧道？`}))return;
 const r=await api('/api/tunnel-stop',{});toast('已停止: '+r.stopped.join(', '));refresh()}

async function addAgent(){const n=await ask({title:'新增机器',input:true,def:'',msg:'新站点名（中文/英文均可，不含空格）：'});if(!n)return;
 const name=n.trim();if(!name)return;
 if(!await ask({title:'新增机器',msg:`确认为【${name}】生成安装包并下载？`}))return;
 genPkg(name,true)}
async function genPkgFor(name){if(!await ask({title:'生成安装包',msg:`确认为【${name}】生成/更新安装包并下载？\n（已部署的同名站点 = 同 id 升级包，不断线）`}))return;genPkg(name,false)}
async function genPkg(name,fresh){toast('生成中…');const r=await api('/api/agent-add',{name});
 if(r.ok){toast('已生成'+(r.reused?'（复用 id '+r.aid+'）':''));location.href='/api/download?path='+encodeURIComponent(r.zip);refresh()}else toast('失败: '+r.err)}
async function rmAgent(name){if(!await ask({title:`删除 ${name}`,danger:true,msg:`确认删除机器【${name}】？\n\n注意：仅删除 hub 注册（该机 agent 若仍在运行会自动重新注册；彻底移除需在该机卸载 agent）。`}))return;
 const r=await api('/api/agent-rm',{name});toast(r.ok?'已删除: '+name:'失败: '+r.err);refresh()}

async function saveCfg2(){const d=document.getElementById('dlDir').value.trim();const r=await api('/api/config',{download_dir:d});toast(r.ok?'下载目录已保存':'失败')}
document.getElementById('rf').addEventListener('change',async e=>{const v=+e.target.value||30;
 const r=await api('/api/config',{refresh:v});if(r.ok){CFG.refresh=v;toast('已保存，下一轮生效（'+v+'s）');schedule()}});
document.getElementById('agFilter').addEventListener('input',renderAgents);
document.getElementById('agStat').addEventListener('change',renderAgents);
document.getElementById('tFilter').addEventListener('input',renderTunnels);
document.addEventListener('keydown',e=>{if(e.key==='Escape')closeModals()});
let _askRes=null,_askVal=false;
function askResolve(ok){const m=document.getElementById('askModal');m.classList.remove('show');
 if(_askRes){const r=_askRes;_askRes=null;r(ok)}}
function ask({title,msg,danger,input,def}){
 return new Promise(res=>{_askRes=res;_askVal=!!input;
  document.getElementById('askTitle').textContent=title||'确认';
  document.getElementById('askMsg').textContent=msg||'';
  const ir=document.getElementById('askInputRow'),ip=document.getElementById('askInput');
  ir.style.display=input?'':'none';if(input){ip.value=def||''}
  const ok=document.getElementById('askOkBtn');
  ok.className=danger?'danger':'pri';ok.textContent=danger?'确认删除':'确认';
  const m=document.getElementById('askModal');m.classList.add('show');
  if(input){ip.onkeydown=e=>{if(e.key==='Enter')askResolve(true)};setTimeout(()=>{ip.focus();ip.select()},50)}
  else setTimeout(()=>ok.focus(),50)})}
function closeModals(){document.querySelectorAll('.modal').forEach(m=>m.classList.remove('show'));
 if(_askRes){const r=_askRes;_askRes=null;r(_askVal?null:false)}}
let timer=null;function schedule(){clearTimeout(timer);timer=setTimeout(()=>{refresh();schedule()},CFG.refresh*1000)}
refresh();schedule();
</script></body></html>'''

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        sys.stderr.write('[%s] %s\n' % (time.strftime('%H:%M:%S'), fmt % args))

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n else b''

    def do_GET(self):
        if self.path == '/' or self.path.startswith('/?'):
            body = PAGE.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith('/api/state'):
            try:
                return self._json(make_state())
            except Exception as e:
                return self._json({'hub_ok': False, 'err': str(e), 'agents': [], 'tunnels': [], 'config': {}})
        if self.path.startswith('/api/download?'):
            from urllib.parse import urlparse, parse_qs, unquote
            q = parse_qs(urlparse(self.path).query)
            path = unquote(q.get('path', [''])[0])
            allowed = False
            for base in (os.path.join(PKG, 'out'), load_cfg().get('download_dir', '')):
                if base and os.path.abspath(path).startswith(os.path.abspath(base)):
                    allowed = True
            if not allowed or not os.path.isfile(path):
                return self._json({'ok': False, 'err': 'forbidden or missing'}, 403)
            data = open(path, 'rb').read()
            self.send_response(200)
            self.send_header('Content-Type', 'application/octet-stream')
            self.send_header('Content-Disposition', 'attachment; filename="%s"' % os.path.basename(path))
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self._json({'err': 'not found'}, 404)

    def do_POST(self):
        try:
            if self.path == '/api/exec':
                b = json.loads(self._body().decode('utf-8'))
                a = agent_by_name(b.get('name', ''))
                if not a:
                    return self._json({'ok': False, 'err': 'agent 不存在'})
                r = exec_on_agent(a['id'], b.get('cmd', ''), int(b.get('timeout') or 0))
                r['ok'] = r.get('exit') is not None
                return self._json(r)
            if self.path == '/api/tunnel':
                b = json.loads(self._body().decode('utf-8'))
                return self._json(spawn_tunnel(b.get('name', ''), b.get('rport') or 80,
                                               b.get('lport') or '', b.get('target') or ''))
            if self.path == '/api/tunnel-stop':
                b = json.loads(self._body().decode('utf-8'))
                return self._json(tunnel_stop(b.get('lport')))
            if self.path == '/api/file-get':
                b = json.loads(self._body().decode('utf-8'))
                dd = load_cfg().get('download_dir') or os.path.join(os.path.expanduser('~'), 'Downloads')
                return self._json(file_get(b.get('name', ''), b.get('rpath', ''), dd))
            if self.path == '/api/file-put':
                from urllib.parse import unquote
                data = self._body()
                name = unquote(self.headers.get('X-Name', ''))
                rpath = unquote(self.headers.get('X-Path', ''))
                origname = unquote(self.headers.get('X-File', ''))
                return self._json(file_put(name, data, rpath, origname))
            if self.path == '/api/agent-rm':
                b = json.loads(self._body().decode('utf-8'))
                a = agent_by_name(b.get('name', ''))
                if not a:
                    return self._json({'ok': False, 'err': 'agent 不存在'})
                hub_post('/purge?admin=%s&id=%s' % (admin_token(), a['id']))
                return self._json({'ok': True})
            if self.path == '/api/agent-rename':
                b = json.loads(self._body().decode('utf-8'))
                a = agent_by_name(b.get('name', ''))
                new = (b.get('new') or '').strip()
                if not a:
                    return self._json({'ok': False, 'err': 'agent 不存在'})
                if not new or len(new) > 40 or any(c in new for c in ' \\/:*?"<>|'):
                    return self._json({'ok': False, 'err': '名称非法（空/含空白或 \/:*?"<>|）'})
                hub_post('/rename?admin=%s&id=%s' % (admin_token(), a['id']),
                         json.dumps({'name': new}, ensure_ascii=False).encode('utf-8'))
                return self._json({'ok': True, 'new': new})
            if self.path == '/api/agent-add':
                b = json.loads(self._body().decode('utf-8'))
                return self._json(agent_add(b.get('name', '')))
            if self.path == '/api/config':
                b = json.loads(self._body().decode('utf-8'))
                cfg = load_cfg()
                if b.get('refresh'):
                    cfg['refresh'] = max(3, int(b['refresh']))
                if b.get('download_dir'):
                    cfg['download_dir'] = b['download_dir']
                save_cfg(cfg)
                return self._json({'ok': True, 'config': cfg})
        except Exception as e:
            return self._json({'ok': False, 'err': str(e)}, 500)
        self._json({'err': 'not found'}, 404)


def main():
    port = 0
    bg = False
    args = sys.argv[1:]
    if '--bg' in args:
        bg = True
        args.remove('--bg')
    if '--port' in args:
        port = int(args[args.index('--port') + 1])
    cfg = load_cfg()
    if not port:
        # 端口粘性：复用上次端口（重启后 URL 不变）；被占才换新
        last = cfg.get('port')
        if last:
            import socket as _sk
            try:
                _sk.create_connection(('127.0.0.1', int(last)), timeout=0.5).close()
                last = None  # 端口仍被占用（可能是残留实例）
            except OSError:
                port = int(last)
        if not last:
            port = free_port()
    cfg['port'] = port
    if bg:
        cfg['pid'] = os.getpid()
    save_cfg(cfg)
    srv = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    url = 'http://127.0.0.1:%d' % port
    print('tailpet 控制台: %s  (%s模式, Ctrl+C 停止)' % (url, '后台' if bg else '前台'), flush=True)
    threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('已停止')

if __name__ == '__main__':
    main()
