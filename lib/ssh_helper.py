#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ssh_helper - 远程执行防坑版（在方案包 params.json 环境下使用）

解决四类坑：
1. 本地 shell 转义：paramiko 直发，不经本地 bash
2. 远端 Windows shell 转义：--ps 模式用 PowerShell EncodedCommand（base64 UTF-16LE），引号/管道/$ 全免疫
3. 中文乱码：输出按 UTF-8 → GBK 双重回退解码（中文 Windows 远端默认 GBK）
4. 挂死/退出码：超时 + 返回远端退出码

用法：
  python ssh_helper.py s "wsl -d Ubuntu -u root pgrep -x headscale"   # 别名来自 params.json
  python ssh_helper.py b "hostname & whoami"                          # B 走 cmd 语法
  python ssh_helper.py --ip 1.2.3.4 -u user -k keyfile -- "命令"       # 临时主机
  python ssh_helper.py s --ps "Get-Service sshd | Select Status"      # 强制 PS 模式
"""
import argparse, base64, json, os, sys
import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)

def load_aliases():
    p = os.path.join(PKG, 'params.json')
    if not os.path.exists(p):
        return {}
    P = json.load(open(p, encoding='utf-8'))
    return {
        's': dict(ip=P['server']['host'], user=P['server']['user'],
                  key=P['a']['ssh_key'], shell='ps',   # S 默认 shell = PowerShell
                  wsl=P['server'].get('wsl_distro', 'Ubuntu')),
        'b': dict(ip=P['b']['tailscale_ip'], user=P['b']['ssh_user'],
                  key=P['a']['ssh_key'], shell='cmd'),  # B 默认 shell = cmd
    }

def smart_decode(b: bytes) -> str:
    for enc in ('utf-8', 'gbk'):
        try:
            return b.decode(enc)
        except UnicodeDecodeError:
            continue
    return b.decode('utf-8', errors='replace')

def to_ps_encoded(ps_script: str) -> str:
    enc = base64.b64encode(('[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' + ps_script).encode('utf-16-le')).decode()
    return 'powershell -NoProfile -EncodedCommand ' + enc

def run(host, user, key, command, shell, timeout=120):
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(host, username=user, key_filename=key, timeout=15,
                look_for_keys=False, allow_agent=False)
    try:
        if shell == 'ps':
            wire = to_ps_encoded(command)
        else:
            wire = command
        stdin, stdout, stderr = cli.exec_command(wire, timeout=timeout)
        out = smart_decode(stdout.read())
        err = smart_decode(stderr.read())
        rc = stdout.channel.recv_exit_status()
        return out.strip(), err.strip(), rc
    finally:
        cli.close()

def main():
    ap = argparse.ArgumentParser(description='SSH 远程执行（防坑版）')
    ap.add_argument('target', help='别名(s/b) 或 IP')
    ap.add_argument('command', help='要执行的命令')
    ap.add_argument('--ip', help='覆盖 IP（target 为别名时）')
    ap.add_argument('-u', '--user')
    ap.add_argument('-k', '--key')
    ap.add_argument('--ps', action='store_true', help='强制 PowerShell EncodedCommand 模式')
    ap.add_argument('--cmd', action='store_true', help='强制原样发送（远端 cmd/bash）')
    ap.add_argument('-t', '--timeout', type=int, default=120)
    args = ap.parse_args()

    aliases = load_aliases()
    cfg = dict(aliases.get(args.target, dict(ip=args.target, user=args.user,
                                             key=args.key or os.path.expanduser('~/.ssh/id_ed25519_voerka'),
                                             shell='cmd')))
    if args.ip: cfg['ip'] = args.ip
    if args.user: cfg['user'] = args.user
    if args.key: cfg['key'] = args.key
    if args.ps: cfg['shell'] = 'ps'
    if args.cmd: cfg['shell'] = 'cmd'
    if not (cfg.get('ip') and cfg.get('user') and cfg.get('key')):
        ap.error('缺少 ip/user/key（检查 params.json 或命令行参数）')

    try:
        out, err, rc = run(cfg['ip'], cfg['user'], cfg['key'], args.command, cfg.get('shell', 'cmd'), args.timeout)
    except Exception as e:
        print(f'错误: {e}', file=sys.stderr)
        sys.exit(2)

    if out:
        sys.stdout.buffer.write((out + '\n').encode('utf-8'))
    if err:
        sys.stderr.buffer.write(('[stderr] ' + err + '\n').encode('utf-8'))
    sys.exit(rc)

if __name__ == '__main__':
    main()
