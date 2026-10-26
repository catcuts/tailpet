# tailpet

自建**组网管理 CLI**：一台公网服务器当控制面（hub），管理机 A 对任意多台现场设备 B **远程执行命令、打开 B 侧才能访问的 web 服务**。被管设备不出一扇入站门——只主动出站连 hub，无需安装任何软件，Windows 自带 PowerShell 即可运行（兼容 PowerShell 2.0 / Server 2008 R2）。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 它解决的问题

散落各处的机器（NAT 后、无公网 IP、不便装软件）如何被一台管理机安全地远程控制。传统做法是逐台配 frp/反向隧道/入站端口；本方案在 B 上放一个**只出站**的常驻 agent：

- **命令通道**——agent 长轮询 hub 领命令、回结果，`tailpet agent exec <名> <命令>` 一条直达
- **TCP 中继**——需要时 agent 临时**出站**拨一条 TCP 到 hub，与 A 的连接在 hub 拼接：A 浏览器打开 `127.0.0.1:端口` 即访问 B（或 B 内网任一机器）的 web/RDP/任意 TCP 服务

## 它工作的原理

三个角色：

- **S**——公网云主机（Windows），跑一个纯标准库 Python 脚本 `hub.py`：`:8443` 命令通道（HTTP 长轮询）+ `:80` TCP 中继
- **A**——你的管理机（Windows + Python 3），本仓库所有命令都在 A 上跑
- **B**——被管现场设备（Windows），`C:\ProgramData\tailpet\agent-v2.ps1` 经计划任务常驻（SYSTEM、隐藏窗口、每分钟自愈、互斥防重）

```
   ┌───────────────────────────────────────────────┐
   │ S · 公网云主机（Windows, 任意能跑 Python3）        │
   │   hub.py :8443  命令通道（长轮询+心跳+结果回传）    │
   │   hub.py :80    TCP 中继（两侧出站汇合点）          │
   └──────┬───────────────────────────┬────────────┘
          │ 出站 :8443                 │ 出站 :8443（轮询）
   ┌──────▼─────────┐        常驻       │  按需 :80（中继）
   │ A · 管理机       │        ┌─────────▼─────────┐
   │ tailpet CLI      │        │ B · 现场设备（任意多）│
   │ + bridge.py      │        │ agent-v2.ps1 常驻    │
   └────────────────┘        └───────────────────┘
```

**A→B 的每一条链路都由 B 主动出站建立**：B 的公网面全黑，防火墙入站一条不用开；hub 只做"信箱 + 拼线工"，不解析业务内容（中继的 HTTPS 端到端加密对 hub 也不可读）。

## 快速开始

**准备材料**：

| 材料 | 要求 | 说明 |
|---|---|---|
| **一台 S（公网服务器）** | Windows，能跑 Python 3.8+，1 核 1G 起步 | 任意云厂商；防火墙放行 TCP 8443、80 |
| **一台 A（管理机）** | 你日常用的 Windows + Python 3 | 无需公网 IP |
| **B 类设备（任意多台）** | Windows，能出公网（仅出站 8443/80） | 无需公网 IP、无需入站放行、无需装任何东西；Git Bash 用户有专用 shim（bin/tailpet） |

**S 上部署 hub**（一次性，现成部署细节见 `docs/环境交接-v2.md`）：

```text
1. 拷 lib/hub.py + 嵌入式 Python（或任意 Python3）到 C:\tailpet-hub\
2. 计划任务常驻拉起：python C:\tailpet-hub\hub.py
3. 防火墙放行 TCP 8443、80
```

**A 上安装**（管理员 PowerShell）：

```powershell
git clone https://github.com/catcuts/tailpet   # 或下载解压
cd tailpet
copy params.example.json params.json           # 填 S 的 IP/用户
powershell -ExecutionPolicy Bypass -File install-tailpet.ps1
```

**接入第一台 B**：

```powershell
tailpet agent add 公司192.168.38.194
# → 生成 out\Agent-Bootstrap-公司192.168.38.194.zip
#   拷到 B 解压，右键 Add-Agent.bat 以管理员身份运行——完成
```

agent 首次心跳即在 hub 自动注册，A 侧立即可见可用。

## 日常操作

```powershell
tailpet agent list                        # agent 表（在线优先→按名排序；VER 列 = agent 版本，- 即待升级）
tailpet agent exec 公司B "ipconfig /all"   # 远程执行（经 hub 下发，非交互）
tailpet agent exec 公司B "ssh-p 密码 root@192.168.38.202 uname -a"   # 操作 B 内网的 C 机（密码模式，C 机零预装）
tailpet agent exec 公司B "ssh-c root@192.168.38.202 uname -a"        # 公钥模式（C 已装 B 的公钥时）
tailpet file get 公司B C:\ProgramData\tailpet\spool\out.log   # 取回该机文件（大输出先落盘再取）
tailpet file put 公司B 本地文件 [该机目标路径]                 # 推文件到该机（hub 分块中转，异步）
tailpet ssh 公司B "hostname"               # 同上（agent 机自动走 hub）
tailpet ssh                               # 交互式选择机器
tailpet nodes                             # 机器总表
tailpet tunnel 公司B 80                    # 本机浏览器打开 B 的 80 端口 web
tailpet tunnel 公司B 8080 192.168.38.201   # 打开 B 内网另一台机器的 8080
tailpet tunnel-stop [本地端口]              # 停止隧道（不带参数=全部）
tailpet web                                # 本机管理页面（浏览器图形化：机器/命令/隧道/文件/安装包）
tailpet tunnel-list                        # 查看活动隧道（失联记录自动清理）
tailpet gen-prompt                        # 生成机器连接说明（复制到剪贴板，喂给 AI 用）
tailpet agent rm <名>                      # 吊销 agent
```

同目标的隧道重复执行会直接复用已有实例，不会越堆越多。中继是透明 TCP：HTTP/HTTPS/WebSocket 皆可用，延迟约等于两次公网往返（实测 ~35ms）。

## 管理页面（tailpet web）

`tailpet web [-p 端口] [-d]` 启动本机管理页面（仅 127.0.0.1 可访问，自动打开浏览器）：机器列表（在线/版本）、下发命令（带确认与超时）、隧道管理、文件取回/推送（下载目录可配置）、生成 agent 安装包（幂等升级）。`-d` 后台运行 + `tailpet web-stop` 停止；危险操作二次确认；自动刷新间隔页面可配（下一轮生效）。

## 安全模型

| 机制 | 说明 |
|---|---|
| agent 令牌 | 每台 B 一枚随机 token（内嵌于其安装包），hub 侧校验，丢包即冒充无门 |
| admin 令牌 | A 侧管理令牌（`%LOCALAPPDATA%\tailpet\hub-admin.txt`，gitignored），命令下发/吊销/中继建立均需它 |
| 吊销 | `tailpet agent rm <名>` 删 hub 全部状态（该 id 立即失联）；已知限制：B 端计划任务需在目标机上删除，见 `docs/环境交接-v2.md` |
| 明文边界 | hub 可见中继的明文 HTTP 流量；HTTPS 端到端加密对 hub 不可读。S 即信任边界 |
| 零入站 | B 公网面全黑；S 仅暴露 8443/80 两个端口 |

## 已知限制

- 中继的每条连接在 B 上对应一个 worker 进程（约 20MB，空闲 10 分钟自动回收）——浏览器多连接会并行多个 worker
- 新连接建立需经命令通道拾取（约 1~3 秒），建立后流式传输无此开销
- 命令通道单命令排队：同时下发多条 exec 时后者覆盖前者（file 中继请求不受此限，独立队列捎带）
- `agent exec` 为非交互单发，默认 120 秒超时（`-Timeout N` 可放宽）；交互式场景请在 B 上直接操作或拆成多条命令
- 大输出命令一律重定向到该机文件再 `file get` 取回——exec 直接回传只适合小结果（<50KB）

## 附：仓库地图

```
tailpet/
├── README.md / CHANGELOG.md / LICENSE(MIT)
├── install-tailpet.ps1        # A 机安装器（程序+PATH+参数模板）
├── tailpet.ps1                # 主 CLI（全局命令 tailpet 的本体）
├── bridge.py                  # 隧道桥（A 本地监听 ↔ hub 中继）
├── bin/tailpet.cmd            # PATH 垫片
├── bootstrap/
│   ├── agent-v2.ps1.template  # agent 模板（tailpet agent add 渲染打包）
│   ├── Add-Agent-V2.bat       # B 端安装入口（UAC 提权）
│   └── cache/OpenSSH-Win64.zip  # 离线 OpenSSH（随安装包内嵌，B→C 的 ssh 客户端）
├── lib/hub.py                 # hub：命令通道 + TCP 中继（纯标准库）
├── deploy.py                  # [v1 历史遗留，v2 不再使用]
├── docs/环境交接-v2.md         # 当前环境交接（端口/路径/凭据位置）
├── docs/部署日志.md            # 历史时间线（v1 架构时期，存档）
├── out/                       # 生成产物【gitignored】
├── params.example.json        # 参数模板
└── params.json                # 环境实参【gitignored】
```

## 推广

推荐**腾讯云轻量应用服务器**做 S：最低配（2C2G）即可，选 Windows Server 镜像、地域就近。

[点此进入腾讯云特惠专区选购（轻量应用服务器即可）](https://cloud.tencent.com/act/cps/redirect?redirect=2446&cps_key=82ac75e750d4ccaa048ca370bc2bd679&from=console)
