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
                        'alive': alive})
    cfg = load_cfg()
    return {'hub_ok': hub_ok, 'agents': agents, 'tunnels': tunnels,
            'config': {'refresh': int(cfg.get('refresh', 30)),
                       'download_dir': cfg.get('download_dir') or
                           os.path.join(os.path.expanduser('~'), 'Downloads')}}

PAGE = r'''<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>tailpet 控制台</title>
<style>
body{font-family:"Microsoft YaHei",sans-serif;margin:0;background:#f4f6f8;color:#222}
header{background:#1f3a5f;color:#fff;padding:10px 18px;display:flex;gap:16px;align-items:center;flex-wrap:wrap}
header b{font-size:17px}
.card{background:#fff;margin:14px;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.12);padding:12px 16px}
h3{margin:2px 0 10px;font-size:14px;color:#1f3a5f;border-bottom:1px solid #e3e8ee;padding-bottom:6px}
table{border-collapse:collapse;width:100%;font-size:13px}
th,td{padding:6px 8px;border-bottom:1px solid #eef1f4;text-align:left}
th{color:#666;font-weight:600;background:#fafbfc}
button{border:1px solid #c5d0dc;background:#fff;border-radius:5px;padding:4px 10px;cursor:pointer;font-size:12px}
button:hover{background:#eef3f9}
button.pri{background:#1f3a5f;color:#fff;border-color:#1f3a5f}
button.warn{color:#b00;border-color:#d99}
input,select{border:1px solid #c5d0dc;border-radius:5px;padding:4px 8px;font-size:12px}
pre{background:#101826;color:#cfe3ff;padding:10px;border-radius:6px;font-size:12px;max-height:260px;overflow:auto;white-space:pre-wrap}
.ok{color:#0a7d32}.off{color:#999}
.tag{display:inline-block;padding:1px 7px;border-radius:9px;font-size:11px}
.on{background:#e2f5e9;color:#0a7d32}.offline{background:#f1f1f1;color:#888}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.hint{font-size:11px;color:#8a97a5}
#toast{position:fixed;bottom:18px;right:18px;background:#123;color:#fff;padding:9px 16px;border-radius:7px;font-size:13px;display:none;z-index:9}
details{margin-top:8px}
</style></head><body>
<header><b>tailpet 控制台</b>
 <span id="hubstat">…</span><span id="cnt"></span>
 <span class="row" style="gap:4px">自动刷新 <input id="rf" style="width:46px"> s
   <span class="hint" id="rfmsg">（改后下一轮生效）</span></span>
 <button onclick="refresh()">立即刷新</button>
</header>

<div class="card"><h3>机器列表</h3>
<table id="agents"><thead><tr><th>名称</th><th>状态</th><th>版本</th><th>最后心跳</th><th>IP</th><th>操作</th></tr></thead><tbody></tbody></table>
</div>

<div class="card" id="execCard" style="display:none"><h3>命令 · <span id="execName"></span></h3>
<div class="row">
 <button onclick="qcmd('hostname')">hostname</button>
 <button onclick="qcmd('ipconfig /all')">ipconfig /all</button>
 <button onclick="qcmd('powershell -NoProfile -Command Get-Host')">Get-Host 版本探测</button>
 自定义 <input id="cmd" style="flex:1;min-width:220px"> 超时 <input id="tmo" value="120" style="width:52px"> s
 <button class="pri" onclick="runExec()">运行</button></div>
<pre id="out">（输出区）</pre>
</div>

<div class="card"><h3>隧道管理</h3>
<div id="tunnels"></div>
<div class="row">新建：机器 <select id="tAgent"></select> 远端端口 <input id="tPort" value="80" style="width:56px">
 本地端口 <input id="tLport" placeholder="自动" style="width:56px"> 目标IP <input id="tTarget" placeholder="该机本机" style="width:110px">
 <button class="pri" onclick="newTunnel()">新建隧道</button></div>
</div>

<div class="card" id="fileCard" style="display:none"><h3>文件传输 · <span id="fileName"></span></h3>
<div class="row">取回：远端路径 <input id="fPath" style="flex:1;min-width:260px" placeholder="C:\ProgramData\tailpet\spool\out.log">
 <button class="pri" onclick="doGet()">取回</button></div>
<div class="row">下载目录 <input id="dlDir" style="flex:1;min-width:220px"> <button onclick="saveCfg2()">保存目录</button></div>
<div class="row">推送：<input type="file" id="fUp"> 目标 <input id="fRemote" placeholder="spool\同名" style="width:180px">
 <button class="pri" onclick="doPut()">推送</button></div>
<pre id="fOut">（传输记录）</pre>
</div>

<div class="card"><h3>安装包生成</h3>
<div class="row">新站点名 <input id="newAgent" placeholder="如 新丰社区B">
 <button class="pri" onclick="genZip()">生成并下载</button>
 <span class="hint">同名 = 幂等升级包（复用 id/token，不断线）</span></div>
</div>

<div id="toast"></div>
<script>
let AG=[],CFG={refresh:30};
function toast(m,ms){const t=document.getElementById('toast');t.textContent=m;t.style.display='block';clearTimeout(t._h);t._h=setTimeout(()=>t.style.display='none',ms||2600)}
async function api(p,body){const r=await fetch(p,body?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)}:undefined);return r.json()}
async function refresh(){
 try{const s=await api('/api/state');AG=s.agents;CFG=s.config;
  document.getElementById('hubstat').innerHTML=s.hub_ok?'<span class="ok">hub ● 在线</span>':'<span style="color:#f66">hub ✖ 不可达</span>';
  document.getElementById('cnt').textContent=`站点 ${s.agents.length} / 在线 ${s.agents.filter(a=>a.online).length}`;
  if(document.activeElement.id!=='rf')document.getElementById('rf').value=s.config.refresh;
  if(document.activeElement.id!=='dlDir')document.getElementById('dlDir').value=s.config.download_dir;
  const tb=document.querySelector('#agents tbody');tb.innerHTML='';
  for(const a of s.agents){const tr=document.createElement('tr');
   tr.innerHTML=`<td>${a.name}</td><td><span class="tag ${a.online?'on':'offline'}">${a.online?'🌍在线':'🚫离线'}</span></td><td>${a.ver}</td><td>${a.seen}</td><td>${a.ip}</td>
   <td><button onclick="openExec('${esc(a.name)}')">命令</button> <button onclick="openFile('${esc(a.name)}')">文件</button> <button onclick="quickTunnel('${esc(a.name)}')">隧道80</button></td>`;tb.appendChild(tr)}
  const sel=document.getElementById('tAgent');const keep=sel.value;sel.innerHTML='';
  for(const a of s.agents){const o=document.createElement('option');o.value=a.name;o.textContent=a.name;sel.appendChild(o)}
  if(keep)sel.value=keep;
  const tv=document.getElementById('tunnels');tv.innerHTML=s.tunnels.length?'':'<span class="hint">（无活动隧道）</span>';
  for(const t of s.tunnels){const d=document.createElement('div');d.className='row';
   d.innerHTML=`<b>${t.port}</b> → ${t.target} <span class="${t.alive?'ok':'off'}">${t.alive?'运行中':'已失联'}</span> <span class="hint">${t.started}</span> <button class="warn" onclick="stopTunnel(${t.port})">停止</button>`;tv.appendChild(d)}
 }catch(e){document.getElementById('hubstat').innerHTML='<span style="color:#f66">控制台服务异常</span>'}
}
function esc(s){return s.replace(/'/g,"\\'")}
function openExec(n){document.getElementById('execCard').style.display='block';document.getElementById('execName').textContent=n;document.getElementById('out').textContent='（输出区）';window.scrollTo(0,document.getElementById('execCard').offsetTop-8)}
function openFile(n){document.getElementById('fileCard').style.display='block';document.getElementById('fileName').textContent=n;window.scrollTo(0,document.getElementById('fileCard').offsetTop-8)}
function qcmd(c){document.getElementById('cmd').value=c;runExec()}
async function runExec(){const n=document.getElementById('execName').textContent,c=document.getElementById('cmd').value.trim(),t=+document.getElementById('tmo').value||120;
 if(!c)return; if(!confirm(`确认在【${n}】执行命令？\n\n${c}\n\n超时 ${t}s`))return;
 document.getElementById('out').textContent='执行中…';
 const r=await api('/api/exec',{name:n,cmd:c,timeout:t});
 document.getElementById('out').textContent=(r.stdout||'')+(r.stderr?'\n[stderr] '+r.stderr:'')+`\n[exit ${r.exit}]`}
async function newTunnel(){const n=tAgent.value,p=+tPort.value||80,l=tLport.value.trim(),t=tTarget.value.trim();
 if(!confirm(`确认新建隧道？\n\n${n} ${t||'本机'}:${p} → 本机 ${l||'自动'}`))return;
 const r=await api('/api/tunnel',{name:n,rport:p,lport:l,target:t});
 toast(r.ok?`隧道已建立: ${r.url}`+(r.reused?'（复用已有）':''):'失败: '+r.err);if(r.ok){window.open(r.url,'_blank');refresh()}}
async function quickTunnel(n){if(!confirm(`确认新建隧道？\n\n${n} :80 → 本机 自动端口`))return;
 const r=await api('/api/tunnel',{name:n,rport:80});toast(r.ok?`隧道: ${r.url}`:'失败: '+r.err);if(r.ok){window.open(r.url,'_blank');refresh()}}
async function stopTunnel(p){if(!confirm(`确认停止隧道 ${p}？`))return;const r=await api('/api/tunnel-stop',{lport:p});toast('已停止: '+r.stopped.join(', '));refresh()}
async function doGet(){const n=document.getElementById('fileName').textContent,p=document.getElementById('fPath').value.trim();
 if(!p)return toast('请填远端路径');toast('取回中…（大文件耐心等待）',30000);
 const r=await api('/api/file-get',{name:n,rpath:p});
 toast(r.ok?`已取回: ${r.local}（${r.size} bytes）`:'失败: '+r.err,5000);
 document.getElementById('fOut').textContent+=`\n${r.ok?'✅':'❌'} ${p} → ${r.local||r.err}`}
async function doPut(){const n=document.getElementById('fileName').textContent,f=document.getElementById('fUp').files[0];
 if(!f)return toast('请选择文件');const rp=document.getElementById('fRemote').value.trim();
 if(!confirm(`确认推送到【${n}】？\n\n${f.name} (${f.size} bytes) → ${rp||'spool\\\\'+f.name}`))return;
 toast('推送中…',30000);
 const buf=await f.arrayBuffer();
 const r=await fetch('/api/file-put',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Name':encodeURIComponent(n),'X-Path':encodeURIComponent(rp||('spool\\'+f.name)),'X-File':encodeURIComponent(f.name)},body:buf}).then(x=>x.json());
 toast(r.ok?'推送完成: '+r.remote:'失败: '+r.err,4000);
 document.getElementById('fOut').textContent+=`\n${r.ok?'✅':'❌'} ${f.name} → ${r.remote||r.err}`}
async function genZip(){const n=document.getElementById('newAgent').value.trim();if(!n)return toast('请填站点名');
 if(!confirm(`确认生成安装包【${n}】？\n（同名站点将生成同 id 升级包）`))return;
 toast('生成中…');const r=await api('/api/agent-add',{name:n});
 if(r.ok){toast('已生成'+(r.reused?'（复用 id '+r.aid+'）':''));location.href='/api/download?path='+encodeURIComponent(r.zip);refresh()}else toast('失败: '+r.err)}
async function saveCfg2(){const d=document.getElementById('dlDir').value.trim();const r=await api('/api/config',{download_dir:d});toast(r.ok?'已保存':'失败')}
document.getElementById('rf').addEventListener('change',async e=>{const v=+e.target.value||30;
 const r=await api('/api/config',{refresh:v});if(r.ok){CFG.refresh=v;toast('已保存，下一轮生效（'+v+'s）');schedule()}});
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
    if not port:
        port = free_port()
    cfg = load_cfg()
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
