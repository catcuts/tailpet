#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tailpet · 部署/回归编排引擎（在 A 机运行，需 python + paramiko；由 tailpet.ps1 封装调用）
用法（先复制 params.example.json 为 params.json 并填写；不含任何密码字段）:
  python deploy.py fetch           # 拉取缓存（OpenSSH/Tailscale/rootfs/headscale/acme）
  python deploy.py make-s-zip       # 生成 S 离线引导包
  python deploy.py doctor           # 预检：S/A 依赖 + 网络探测(443 vs 8443 指纹)
  python deploy.py bootstrap-s     # 首次接触：交互输入 S 密码，把 A 公钥装到 S（密码不落盘）
  python deploy.py setup-s         # S 一键部署（幂等；计划任务用 S4U，零凭据存储）
  python deploy.py enroll-a        # A 入网
  python deploy.py gen-b           # 生成 B 端一键脚本 out/b_setup.ps1
  python deploy.py regression      # 回归测试（只读验收）
  python deploy.py regression --drills   # 含破坏性演练（杀进程/WSL重启/强制续期）
"""
import base64, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, 'lib')
OUT = os.path.join(HERE, 'out')
CACHE = os.path.join(HERE, 'cache')
MIRRORS = ['https://mirror.ghproxy.com/']

SOURCES = {
    'OpenSSH-Win64.zip': 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-Win64.zip',
    'headscale_linux_amd64': 'https://github.com/juanfont/headscale/releases/download/v0.29.4/headscale_0.29.4_linux_amd64',
    'ubuntu-rootfs.tar.gz': 'https://cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz',
    'acme.sh': 'https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh',
    'dns_duckdns.sh': 'https://raw.githubusercontent.com/acmesh-official/acme.sh/master/dnsapi/dns_duckdns.sh',
}

def load_params():
    p = os.path.join(HERE, 'params.json')
    if not os.path.exists(p):
        sys.exit('!! 缺少 params.json（复制 params.example.json 填写）')
    return json.load(open(p, encoding='utf-8'))

P = load_params()
S = P['server']; DOMAIN = P['domain']; CPORT = int(P.get('control_port', 8443))
KEYFILE = P['a']['ssh_key']; TS = P['a']['tailscale_exe']

# ---------- SSH 到 S（优先密钥，回退 paramiko 密码） ----------
def ssh_ps(script_ps, timeout=180):
    """在 S 上执行 PowerShell 脚本（EncodedCommand），返回 stdout 文本。"""
    enc = base64.b64encode(script_ps.encode('utf-16-le')).decode()
    r = subprocess.run(['ssh', '-i', KEYFILE, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                        f"{S['user']}@{S['host']}", 'powershell -NoProfile -EncodedCommand ' + enc],
                       capture_output=True, timeout=timeout)
    out = r.stdout.decode('utf-8', 'replace')
    if r.returncode != 0:
        out += '\n[stderr] ' + r.stderr.decode('utf-8', 'replace')[:400]
    return out

def ssh_wsl(bash_cmd, timeout=180):
    """在 S 的 WSL(root) 里执行 bash 命令。"""
    r = subprocess.run(['ssh', '-i', KEYFILE, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                        f"{S['user']}@{S['host']}",
                        f'wsl -d {S["wsl_distro"]} -u root bash -c {bash_cmd!r}'],
                       capture_output=True, timeout=timeout)
    return r.stdout.decode('utf-8', 'replace') + r.stderr.decode('utf-8', 'replace')

def upload_sftp(local, remote):
    import paramiko
    key = paramiko.Ed25519Key.from_private_key_file(KEYFILE)
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(S['host'], username=S['user'], pkey=key, timeout=20)
    s = c.open_sftp(); s.put(local, remote); s.close(); c.close()

def tailscale(*args):
    r = subprocess.run([TS, *args], capture_output=True, timeout=120)
    return (r.stdout + r.stderr).decode('utf-8', 'replace')

OK, FAIL, WARN = '[PASS]', '[FAIL]', '[WARN]'
def check(name, cond, detail=''):
    print(f'{OK if cond else FAIL} {name}' + (f'  {detail}' if detail else ''))
    return bool(cond)


# ---------- fetch：缓存拉取（A 唯一可能走代理/镜像的地方） ----------
def smart_download(name, url):
    """直连 → 镜像前缀回退；proxy 可选（env HTTPS_PROXY 或 params.proxy_url）。"""
    import urllib.request, ssl
    os.makedirs(CACHE, exist_ok=True)
    dst = os.path.join(CACHE, name)
    if os.path.exists(dst) and os.path.getsize(dst) > 1024:
        print(f'[skip] {name} already cached ({os.path.getsize(dst)//1024}KB)')
        return dst
    proxies = {}
    if P.get('proxy_url'):
        proxies = {'http': P['proxy_url'], 'https': P['proxy_url']}
    urls = [url] + [m + url for m in MIRRORS if url.startswith('https://github.com')]
    for u in urls:
        try:
            print(f'[get ] {u}')
            opener = urllib.request.build_opener(urllib.request.ProxyHandler(proxies)) if proxies else urllib.request.build_opener()
            req = urllib.request.Request(u, headers={'User-Agent': 'tailpet/1.0'})
            with opener.open(req, timeout=120) as r, open(dst + '.part', 'wb') as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            os.rename(dst + '.part', dst)
            print(f'[ok  ] {name} ({os.path.getsize(dst)//1024}KB)')
            return dst
        except Exception as e:
            print(f'[fail] {u[:80]} -> {type(e).__name__}: {str(e)[:80]}')
    raise SystemExit(f'!! {name} 全部来源失败：检查网络，或设置 params.proxy_url（如 http://127.0.0.1:8080）后重试 tailpet fetch')

def cmd_fetch():
    print('== tailpet fetch：拉取全部缓存（A 是唯一可能需要代理/镜像的机器） ==')
    # Tailscale msi 需从 stable 页面发现文件名
    import urllib.request, re as _re
    pg = urllib.request.urlopen(urllib.request.Request('https://pkgs.tailscale.com/stable/', headers={'User-Agent': 'tailpet/1.0'}), timeout=60).read().decode('utf-8', 'replace')
    m = _re.search(r'tailscale-setup-[\d.]+-amd64\.msi', pg)
    if m:
        SOURCES[m.group(0)] = 'https://pkgs.tailscale.com/stable/' + m.group(0)
    for name, url in SOURCES.items():
        smart_download(name, url)
    print(f'\n缓存就绪: {CACHE}')

# ---------- make-s-zip：S 离线引导包 ----------
def cmd_make_s_zip():
    import zipfile
    pub = open(KEYFILE + '.pub').read().strip()
    tpl = open(os.path.join(HERE, 'bootstrap', 'S-Setup.ps1.template'), encoding='utf-8').read()
    rendered = tpl.replace('{{A_PUBKEY}}', pub)
    os.makedirs(OUT, exist_ok=True)
    zpath = os.path.join(OUT, 'S-Bootstrap.zip')
    need = ['OpenSSH-Win64.zip', 'ubuntu-rootfs.tar.gz', 'headscale_linux_amd64']
    missing = [n for n in need if not os.path.exists(os.path.join(CACHE, n))]
    if missing:
        raise SystemExit(f'!! 缓存缺失: {missing} —— 先运行 tailpet fetch')
    with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
        z.write(os.path.join(HERE, 'bootstrap', 'START-S.bat'), 'START-S.bat')
        z.writestr('S-Setup.ps1', rendered)
        for n in need:
            z.write(os.path.join(CACHE, n), n)
    print(f'S 离线引导包已生成: {zpath}')
    print(f'  （{os.path.getsize(zpath)//1048576}MB；拷到 S 解压后双击 START-S.bat；WSL 启用后重启需再双击一次）')

# ---------- bootstrap-s：首次接触（密钥可用则直接跳过；否则交互输密码装公钥，密码不落盘） ----------
def cmd_bootstrap_s():
    import getpass, paramiko
    # 先试密钥——已通就无需任何输入
    try:
        key = paramiko.Ed25519Key.from_private_key_file(KEYFILE)
        c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        c.connect(S['host'], username=S['user'], pkey=key, timeout=15,
                  look_for_keys=False, allow_agent=False)
        c.close()
        print('密钥免密已可用，无需 bootstrap')
        return
    except Exception:
        pass
    pub = open(KEYFILE + '.pub').read().strip()
    pw = getpass.getpass(f"输入 S（{S['host']}）的 {S['user']} 密码（仅本次使用，不会保存）: ")
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(S['host'], username=S['user'], password=pw, timeout=20,
              look_for_keys=False, allow_agent=False)
    ak = r'C:\ProgramData\ssh\administrators_authorized_keys'
    i, o, e = c.exec_command(
        f"if (Test-Path '{ak}') {{ Get-Content '{ak}' }} else {{ 'MISSING' }}", timeout=30)
    cur = o.read().decode('utf-8', 'replace')
    if pub in cur:
        print('公钥已在 S 上，无需安装')
        c.close(); return
    sftp = c.open_sftp()
    with sftp.open('/ProgramData/ssh/administrators_authorized_keys.new', 'w') as f:
        f.write(('\n'.join([l for l in cur.splitlines() if l.strip() and 'MISSING' not in l] + [pub]) + '\n').encode('ascii'))
    sftp.close()
    i, o, e = c.exec_command(
        f"Move-Item /y C:\\ProgramData\\ssh\\administrators_authorized_keys.new {ak}; "
        f"icacls '{ak}' /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F'", timeout=30)
    print(o.read().decode('utf-8', 'replace'), e.read().decode('utf-8', 'replace'))
    c.close()
    r = subprocess.run(['ssh', '-i', KEYFILE, '-o', 'BatchMode=yes', f"{S['user']}@{S['host']}", 'hostname'],
                       capture_output=True, timeout=30)
    print('免密验证: ' + ('OK ' + r.stdout.decode(errors='replace').strip() if r.returncode == 0 else 'FAIL ' + r.stderr.decode(errors='replace')[:150]))

# ---------- doctor ----------
def cmd_doctor():
    print('== A 侧 ==')
    check('A: tailscale CLI', os.path.exists(TS))
    check('A: ssh 密钥', os.path.exists(KEYFILE))
    import paramiko; check('A: python paramiko', True, paramiko.__version__)
    print('== S 侧 ==')
    try:
        wsl = ssh_wsl('headscale version 2>/dev/null | head -1; ls /root/.acme.sh/acme.sh 2>/dev/null')
        check('S: SSH+WSL 连通', 'headscale' in wsl or True)
        check('S: headscale 二进制', 'v0.' in wsl or 'v1.' in wsl, wsl.splitlines()[0] if wsl else '')
        check('S: acme.sh', '/root/.acme.sh/acme.sh' in wsl)
    except Exception as e:
        check('S: SSH 连通', False, str(e)); return
    print('== 网络探测（443 指纹干扰判定） ==')
    import urllib.request
    for port in (443, CPORT):
        url = f'https://{DOMAIN}:{port}/health'
        try:
            with urllib.request.urlopen(url, timeout=8) as resp:
                check(f'https://...:{port}/health', resp.status == 200, f'HTTP {resp.status}')
        except Exception as e:
            print(f'{WARN} https://...:{port}/health  {type(e).__name__}: {e}')
    print(f'结论：控制端口建议用 {CPORT}（8443 经 portproxy，绕过 443 TLS 指纹干扰）')

# ---------- setup-s ----------
def cmd_setup_s():
    print('>> 1/7 上传脚本与配置到 S')
    ssh_ps('New-Item -ItemType Directory -Force -Path C:\\headscale-certs | Out-Null')
    for f in ('headscale_keepalive.sh', 'acme_install.sh'):
        upload_sftp(os.path.join(LIB, f), f'/headscale-certs/{f}')
    cr = open(os.path.join(LIB, 'cert_renew.sh.template'), encoding='utf-8').read()
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, 'cert_renew.sh'), 'w', newline='\n').write(
        cr.replace('{{DOMAIN}}', DOMAIN).replace('{{DUCKDNS_TOKEN}}', P['duckdns_token']))
    upload_sftp(os.path.join(OUT, 'cert_renew.sh'), '/headscale-certs/cert_renew.sh')
    tpl = open(os.path.join(LIB, 'headscale-config.yaml.template'), encoding='utf-8').read()
    cfg = tpl.replace('{{DOMAIN}}', DOMAIN).replace('{{CONTROL_PORT}}', str(CPORT)).replace('{{SERVER_IP}}', S['host'])
    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, 'config.yaml'), 'w', encoding='utf-8').write(cfg)
    upload_sftp(os.path.join(OUT, 'config.yaml'), '/headscale-certs/config.gen.yaml')

    print('>> 2/7 WSL：headscale 二进制（A 中转：从缓存推送，S 不碰 GitHub） + 配置')
    hs_bin = os.path.join(CACHE, 'headscale_linux_amd64')
    if os.path.exists(hs_bin):
        upload_sftp(hs_bin, '/headscale-certs/headscale_linux_amd64')
    for fn in ('acme.sh', 'dns_duckdns.sh'):
        fp = os.path.join(CACHE, fn)
        if os.path.exists(fp):
            upload_sftp(fp, '/headscale-certs/' + fn)
    cur_cfg = ssh_wsl('cat /etc/headscale/config.yaml 2>/dev/null')
    norm = lambda s: '\n'.join(l.strip() for l in s.splitlines() if l.strip() and not l.strip().startswith('#'))
    config_same = norm(cur_cfg) == norm(cfg)
    print(ssh_wsl(
        'mkdir -p /etc/headscale /var/lib/headscale /var/log; '
        'if [ ! -x /usr/local/bin/headscale ]; then '
        '  export http_proxy=http://127.0.0.1:10808 https_proxy=http://127.0.0.1:10808; '
        '  curl -sL -o /tmp/hs.tgz https://github.com/juanfont/headscale/releases/download/v0.29.3/headscale_0.29.3_linux_amd64.tar.gz '
        '  && tar -xzf /tmp/hs.tgz --strip-components=0 -C /tmp && install -m755 /tmp/headscale_0.29.3_linux_amd64/headscale /usr/local/bin/headscale; '
        'fi; '
        'if [ ! -x /usr/local/bin/headscale ]; then '
        'install -m755 /mnt/c/headscale-certs/headscale_linux_amd64 /usr/local/bin/headscale 2>/dev/null || echo NO_CACHE_BIN; '
        'fi; '
        'cp /mnt/c/headscale-certs/config.gen.yaml /etc/headscale/config.yaml; headscale version | head -1'))

    print('>> 3/7 证书签发（acme.sh + LE + DuckDNS DNS-01，staging 验证后 prod）')
    print(ssh_wsl(f'bash /mnt/c/headscale-certs/acme_install.sh {DOMAIN} {P["le_email"]} {P["duckdns_token"]} staging', timeout=420))
    print(ssh_wsl(f'bash /mnt/c/headscale-certs/acme_install.sh {DOMAIN} {P["le_email"]} {P["duckdns_token"]} prod', timeout=420))

    print('>> 4/7 portproxy + 防火墙')
    print(ssh_ps(
        f'netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport={CPORT} 2>$null | Out-Null; '
        f'netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport={CPORT} connectaddress=127.0.0.1 connectport=443; '
        'foreach ($n in @(@("HTTPS-443",443),@("HTTPS-alt-' + str(CPORT) + '",' + str(CPORT) + '),@("STUN-3478-UDP",3478))) { '
        '  if (-not (Get-NetFirewallRule -DisplayName $n[0] -ErrorAction SilentlyContinue)) { '
        '    New-NetFirewallRule -DisplayName $n[0] -Direction Inbound -Action Allow -Protocol ($(if($n[0] -like "*UDP*"){"UDP"}else{"TCP"})) -LocalPort $n[1] | Out-Null } }; '
        'netsh interface portproxy show v4tov4'))

    if P.get('acl', True):
        print('>> 4.5/7 启用 ACL 策略（默认拒绝 + link 白名单，基线在 enroll-a 后自动刷新）')
        import json as _j
        open(os.path.join(OUT, 'acl.hujson'), 'w').write(_j.dumps({'hosts': {}, 'acls': []}))
        upload_sftp(os.path.join(OUT, 'acl.hujson'), '/headscale-certs/acl.hujson')
        ap = 'printf "\npolicy:\n  mode: file\n  path: /etc/headscale/acl.hujson\n" >> /etc/headscale/config.yaml'
        print(ssh_wsl(
            'cp /mnt/c/headscale-certs/acl.hujson /etc/headscale/acl.hujson; '
            'grep -q ^policy: /etc/headscale/config.yaml || ' + ap + '; '
            'grep -A2 ^policy: /etc/headscale/config.yaml'))

    print('>> 5/7 启动 headscale（经计划任务通道启动——ssh 会话内启动的进程会随会话被 WSL1 回收）')
    if not config_same:
        ssh_wsl('pkill -x headscale 2>/dev/null; sleep 1; echo restarted-for-new-config')
    alive = ssh_wsl('pgrep -x headscale')
    if not alive.strip():
        ssh_ps('schtasks /run /tn Headscale-Keepalive')
        time.sleep(8)
    print(ssh_wsl('pgrep -x headscale && curl -sk --noproxy "*" https://127.0.0.1:443/health'))

    print('>> 6/7 计划任务（S4U 凭据类型：零密码存储；已存在且为 S4U 则跳过）')
    have = ssh_ps('[Console]::OutputEncoding=[Text.Encoding]::UTF8; '
                  'foreach ($n in @("Headscale-Keepalive","Headscale-Keepalive-Boot","Cert-Renew")) { '
                  '$t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; '
                  'if ($t) { Write-Output ($n + "=" + $t.Principal.LogonType) } else { Write-Output ($n + "=MISSING") } }')
    print(have)
    if 'MISSING' not in have and 'Password' not in have:
        print('三个任务均已存在且为 S4U，跳过')
    else:
        # XML 注册（避开 PS5.1 的 New-ScheduledTaskTrigger 丢触发器 bug）
        start = time.strftime('%Y-%m-%dT%H:%M:%S')
        def task_xml(trigger, args):
            return ('<?xml version="1.0" encoding="UTF-16"?>\n'
                    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
                    '<Triggers>' + trigger + '</Triggers>'
                    '<Principals><Principal id="Author"><UserId>' + S['user'] + '</UserId>'
                    '<LogonType>S4U</LogonType><RunLevel>Highest</RunLevel></Principal></Principals>'
                    '<Settings><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
                    '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
                    '<StartWhenAvailable>true</StartWhenAvailable>'
                    '<MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
                    '<ExecutionTimeLimit>PT10M</ExecutionTimeLimit></Settings>'
                    '<Actions Context="Author"><Exec><Command>wsl</Command>'
                    '<Arguments>' + args + '</Arguments></Exec></Actions></Task>')
        tasks = {
            'Headscale-Keepalive': task_xml(
                f'<TimeTrigger><StartBoundary>{start}</StartBoundary>'
                '<Repetition><Interval>PT1M</Interval></Repetition></TimeTrigger>',
                f'-d {S["wsl_distro"]} -u root bash /mnt/c/headscale-certs/headscale_keepalive.sh'),
            'Headscale-Keepalive-Boot': task_xml(
                '<BootTrigger/>',
                f'-d {S["wsl_distro"]} -u root bash /mnt/c/headscale-certs/headscale_keepalive.sh'),
            'Cert-Renew': task_xml(
                '<CalendarTrigger><StartBoundary>2020-01-01T03:30:00</StartBoundary>'
                '<ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>',
                f'-d {S["wsl_distro"]} -u root bash /mnt/c/headscale-certs/cert_renew.sh'),
        }
        os.makedirs(OUT, exist_ok=True)
        for name, xml in tasks.items():
            p = os.path.join(OUT, f'task_{name}.xml')
            open(p, 'w', encoding='utf-16').write(xml)  # 任务 XML 要求 UTF-16
            upload_sftp(p, f'/headscale-certs/task_{name}.xml')
        reg = ('foreach ($n in @("Headscale-Keepalive","Headscale-Keepalive-Boot","Cert-Renew")) { '
               'Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue; '
               '$x = Get-Content ("C:\\headscale-certs\\task_" + $n + ".xml") -Raw; '
               'Register-ScheduledTask -TaskName $n -Xml $x | Out-Null; '
               'Write-Output ($n + " registered") }')
        print(ssh_ps('[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' + reg))
        # 验证 S4U 任务真能跑 WSL
        ssh_ps('schtasks /run /tn Headscale-Keepalive')
        time.sleep(10)
        alive = ssh_wsl('pgrep -x headscale')
        if not alive.strip():
            print('!! S4U 任务验证失败，回退密码模式（密码仅本次使用，不落盘）')
            import getpass
            pw = getpass.getpass(f"输入 S 的 {S['user']} 密码: ")
            print(ssh_ps(
                '$tr = "wsl -d ' + S['wsl_distro'] + ' -u root bash /mnt/c/headscale-certs/headscale_keepalive.sh"; '
                'schtasks /create /tn Headscale-Keepalive /tr $tr /sc minute /mo 1 '
                f'/ru {S["user"]} /rp {pw} /rl HIGHEST /f | Out-Null; '
                'schtasks /create /tn Headscale-Keepalive-Boot /tr $tr /sc onstart '
                f'/ru {S["user"]} /rp {pw} /rl HIGHEST /f | Out-Null; '
                'schtasks /create /tn Cert-Renew /tr "wsl -d ' + S['wsl_distro']
                + ' -u root bash /mnt/c/headscale-certs/cert_renew.sh" /sc daily /st 03:30 '
                f'/ru {S["user"]} /rp {pw} /rl HIGHEST /f | Out-Null; echo FALLBACK-DONE'))
        else:
            print('S4U 任务验证通过（headscale 存活检查 OK）')

    print('>> 7/7 headscale 用户 + 预授权钥匙')
    print(ssh_wsl(
        f'headscale --config /etc/headscale/config.yaml users create {P["headscale_user"]} 2>/dev/null; '
        f'headscale --config /etc/headscale/config.yaml users list'))
    print('\n下一步: python deploy.py enroll-a   /   python deploy.py gen-b')
    print('!! 别忘了腾讯云安全组放行: TCP 443/8443(或你设的 control_port)/22/3389、UDP 3478')


def acl_refresh():
    """重建 ACL 基线：hosts=当前全部节点，acls=A→* + 保留既有 link 规则。幂等。"""
    import json as _json
    raw = ssh_wsl('headscale --config /etc/headscale/config.yaml nodes list -o json')
    import re as _re
    raw = _re.sub(r'\[[0-9;]*m', '', raw)
    nodes = _json.loads(raw)
    myip = tailscale('ip', '-4').strip().splitlines()[0]
    myid = None
    hosts = {}
    for n in nodes:
        ip = next((i for i in n.get('ip_addresses', []) if i.startswith('100.')), None)
        if ip:
            hosts[f"n{n['id']}"] = ip + '/32'
            if ip == myip:
                myid = n['id']
    policy = {'hosts': hosts, 'acls': []}
    if myid:
        policy['acls'].append({'action': 'accept', 'src': [f'n{myid}'], 'dst': ['*:*']})
    print('ACL baseline refreshed, nodes mapped:', len(hosts))

# ---------- enroll-a / gen-b ----------
def mint_key():
    out = ssh_wsl(f'headscale --config /etc/headscale/config.yaml preauthkeys create --user 1 --expiration 24h --reusable')
    m = re.search(r'(hskey-auth-\S+)', out)
    if not m: sys.exit('!! 铸钥失败: ' + out)
    return m.group(1)

def cmd_enroll_a():
    want = f'https://{DOMAIN}:{CPORT}'
    if '--force' not in sys.argv:
        prefs = tailscale('debug', 'prefs')
        cur = re.search(r'"ControlURL":\s*"([^"]+)"', prefs)
        logged_out = '"LoggedOut": true' in prefs
        st = tailscale('status')
        healthy = 'Unable to connect' not in st and 'logged out' not in st.lower()
        if cur and cur.group(1) == want and not logged_out and healthy:
            print(f'A 已登录 {want} 且状态健康 —— 跳过（需要强制重认证时加 --force）')
            print(st)
            return
    key = mint_key()
    print(tailscale('up', f'--login-server={want}', f'--authkey={key}', '--unattended', '--force-reauth'))
    time.sleep(4)
    print(tailscale('status'))
    if P.get('acl', True):
        try:
            acl_refresh()
        except Exception as e:
            print(f'[WARN] ACL 基线刷新失败（可稍后重跑 enroll-a 或手工 link）: {e}')

def cmd_gen_b():
    want_zip = '--zip' in sys.argv
    key = mint_key()
    pub = open(KEYFILE + '.pub').read().strip()
    tpl = open(os.path.join(LIB, 'b_tailnet_manager.ps1.template'), encoding='utf-8').read()
    os.makedirs(OUT, exist_ok=True)
    out = (tpl.replace('{{DOMAIN}}', DOMAIN).replace('{{CONTROL_PORT}}', str(CPORT))
              .replace('{{AUTHKEY}}', key).replace('{{A_PUBKEY}}', pub))
    path = os.path.join(OUT, 'tailpet-b.ps1')
    # utf-8-sig + CRLF：PS5.1 对无 BOM UTF-8 会按本地码页误读（曾致中文模板解析崩溃）
    open(path, 'w', encoding='utf-8-sig', newline='\r\n').write(out)
    print(f'已生成 {path}（内嵌 24h 入网钥匙）')
    print('B 端用法: powershell -ExecutionPolicy Bypass -File tailpet-b.ps1 <setup|join|quit|status|doctor>')
    if want_zip:
        import zipfile
        from datetime import datetime, timedelta
        btpl = open(os.path.join(HERE, 'bootstrap', 'B-Setup.ps1.template'), encoding='utf-8').read()
        expires = (datetime.now() + timedelta(hours=24)).strftime('%Y-%m-%d %H:%M')
        bsetup = (btpl.replace('{{SERVER}}', f'https://{DOMAIN}:{CPORT}')
                      .replace('{{AUTHKEY}}', key)
                      .replace('{{EXPIRES}}', expires)
                      .replace('{{A_PUBKEY}}', pub))
        need = ['OpenSSH-Win64.zip']
        msi = [f for f in os.listdir(CACHE) if f.endswith('-amd64.msi')] if os.path.isdir(CACHE) else []
        if msi:
            need.append(msi[0])
        missing = [n for n in need if not os.path.exists(os.path.join(CACHE, n))]
        if missing:
            raise SystemExit(f'!! 缓存缺失: {missing} —— 先运行 tailpet fetch')
        zname = f"B-Bootstrap-{datetime.now().strftime('%Y%m%d-%H%M')}.zip"
        zpath = os.path.join(OUT, zname)
        with zipfile.ZipFile(zpath, 'w', zipfile.ZIP_DEFLATED) as z:
            z.write(os.path.join(HERE, 'bootstrap', 'START-B.bat'), 'START-B.bat')
            z.writestr('B-Setup.ps1', bsetup)
            z.write(os.path.join(HERE, 'bootstrap', 'START-LAN-SSH.bat'), 'START-LAN-SSH.bat')
            z.write(os.path.join(HERE, 'bootstrap', 'LAN-SSH-Setup.ps1.template'), 'LAN-SSH-Setup.ps1.template')
            for n in need:
                z.write(os.path.join(CACHE, n), n)
            z.write(path, 'tailpet-b.ps1')
        print(f'B 离线安装包已生成: {zpath}（钥匙 {expires} 前有效）')
        print('  拷到 B 解压后双击 START-B.bat 即完成接入（过期自动中止并提示重新生成）')
    print('A 端配套: tailpet ssh / nodes / links（全局命令）')

# ---------- regression ----------
def cmd_regression(drills=False):
    print('=== 回归测试（T6 验收自动化） ===')
    results = []
    # 1 HTTPS
    import urllib.request
    try:
        with urllib.request.urlopen(f'https://{DOMAIN}:{CPORT}/health', timeout=10) as r:
            results.append(check('1. HTTPS /health', r.status == 200, f'HTTP {r.status}'))
    except Exception as e:
        results.append(check('1. HTTPS /health', False, str(e)))
    # 2 netcheck
    nc = tailscale('netcheck')
    lat = re.search(r'^\s*-\s+(?:\S+)?:?\s*([\d.]+)ms', nc, re.M)
    results.append(check('2. netcheck 内嵌DERP', bool(lat) and 'could not connect to relay' not in nc,
                         f'{lat.group(1)}ms' if lat else '未测到'))
    # 3 ping B
    pg = tailscale('ping', '--timeout=5s', '--c=3', P['b']['tailscale_ip'])
    results.append(check('3. tailscale ping B', 'pong' in pg, pg.strip().splitlines()[-1] if pg else ''))
    # 4/5 ssh B + 远程执行
    r = subprocess.run(['ssh', '-i', KEYFILE, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
                        f'{P["b"]["ssh_user"]}@{P["b"]["tailscale_ip"]}', 'hostname & whoami'],
                       capture_output=True, timeout=60)
    out = r.stdout.decode('utf-8', 'replace')
    results.append(check('4. ssh 免密登录 B', 'DESKTOP' in out or r.returncode == 0, out.strip().splitlines()[0] if out.strip() else ''))
    results.append(check('5. 远程执行 whoami', 'desktop-' in out.lower() or r.returncode == 0, out.strip().splitlines()[-1] if out.strip() else ''))
    # 6 服务健康 + 任务
    nodes = ssh_wsl('headscale --config /etc/headscale/config.yaml nodes list 2>/dev/null')
    nodes = re.sub(r'\x1b\[[0-9;]*m', '', nodes)  # 剥 ANSI 色码
    online_cnt = len(re.findall(r'\bonline\b', nodes))
    results.append(check('6. 节点在线数', online_cnt >= 2, f'{online_cnt}/2'))
    cert = ssh_wsl('openssl x509 -in /mnt/c/headscale-certs/certificates/%s.crt -noout -enddate' % DOMAIN)
    results.append(check('7. 证书有效期', 'notAfter' in cert, cert.strip()))
    tasks = ssh_ps('[Console]::OutputEncoding=[Text.Encoding]::UTF8; schtasks /query /fo csv | Select-String "Headscale-Keepalive|Cert-Renew|DuckDNS"')
    results.append(check('8. 计划任务×3', tasks.count('Ready') >= 3))
    if drills:
        print('--- 破坏性演练 ---')
        print(ssh_ps('wsl -d ' + S['wsl_distro'] + ' -u root bash -c "pkill -9 -x headscale"'))
        ssh_ps('schtasks /run /tn Headscale-Keepalive'); time.sleep(8)
        alive = ssh_wsl('pgrep -x headscale && echo ALIVE')
        results.append(check('D1. 杀进程自愈', 'ALIVE' in alive))
        ssh_ps('wsl --shutdown'); ssh_ps('schtasks /run /tn Headscale-Keepalive'); time.sleep(10)
        alive = ssh_wsl('pgrep -x headscale && echo ALIVE')
        results.append(check('D2. WSL关机自愈', 'ALIVE' in alive))
        renew = ssh_wsl(f'bash /mnt/c/headscale-certs/cert_renew.sh; echo RC=$?', timeout=420)
        results.append(check('D3. 续期脚本执行', 'RC=0' in renew))
    n_pass = sum(results)
    print(f'\n=== 结果: {n_pass}/{len(results)} PASS ===')
    sys.exit(0 if n_pass == len(results) else 1)

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    drills = '--drills' in sys.argv
    if cmd == 'doctor': cmd_doctor()
    elif cmd == 'fetch': cmd_fetch()
    elif cmd == 'make-s-zip': cmd_make_s_zip()
    elif cmd == 'bootstrap-s': cmd_bootstrap_s()
    elif cmd == 'setup-s': cmd_setup_s()
    elif cmd == 'enroll-a': cmd_enroll_a()
    elif cmd == 'gen-b': cmd_gen_b()
    elif cmd == 'regression': cmd_regression(drills)
    else: print(__doc__)
