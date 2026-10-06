# tailpet

自建 Headscale/Tailscale 组网的**部署 · 管理 · 回归测试**一体化工具集。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## 它解决的问题

散落各处的机器（NAT 后、无公网 IP）如何被一台管理机安全地远程执行命令。传统做法是逐台搭反向隧道、手工维护；本方案是自建一个控制面（headscale），让所有机器组成一张 WireGuard 加密网（tailnet）——被管设备只需能出公网，即可被管理机免密直达，流量端到端加密。

## 它应用的场景

- **AI Agent / 自动化脚本运维分散的机器**——让 agent 像登录本机一样登录散落各处的设备执行命令（本项目的出身场景）
- **替代逐台手工维护的反向隧道 / frp / 内网穿透**——组一次网，任意两台机器互通，不用为每台设备单独配一条隧道
- **无人值守设备的管理与巡检**——服务器、测试机、工控机、云主机：远程执行、健康体检、批量操作
- **跨网段 / 跨地域的设备互访**——内网服务（数据库、管理界面、文件）经加密网直达，与双方所处 NAT/防火墙无关
- **数据不经第三方的私有组网**——相比 Tailscale 官方云，控制面自持，节点名单与密钥协商不出自己的服务器

## 它工作的原理

三个角色：

- **S**——公网云主机一台（Windows + WSL），跑 headscale 当控制面，兼做中继和证书自动续期
- **A**——你的管理机，持有管理私钥（整套体系的唯一信任根），本仓库所有命令都在 A 上跑
- **B 类**——被管的现场设备，任意多台，可以在任意 NAT 后面

一台 B 从接入到你敲下第一条命令，完整旅程是：

```
① A 铸钥匙        ② B 报到            ③ S 发通讯录           ④ A 直达 B
  a_tailnet_        b_tailnet_           headscale 给 B 发      ssh user@100.64.0.x
  manager key   →   manager setup   →   内网IP + 全网名单  →    WireGuard 加密隧道
  (24h有效)         (装客户端+出示钥匙)    (netmap，本地缓存)
```

此后 B 与 S 只保持一条轻量的长轮询（收发名单更新），**A→B 的实际流量不经过 S**：

```
   ┌──────────────────────────────────────────────────┐
   │ S · 公网云主机（Windows + WSL）                      │
   │   headscale 控制面(TLS) + 内置DERP中继 + STUN        │
   │   ・监听 :443，经 portproxy 再暴露 :8443（见"为什么"） │
   │   acme.sh：Let's Encrypt 证书 90天 DNS-01 自动续期   │
   │   计划任务：每分钟保活 / 开机拉起 / 每日续期检查        │
   └─────┬────────────────────────────────┬───────────┘
         │ :8443 控制面长轮询               │ :8443
   ┌─────▼──────────┐            ┌────────▼──────────┐
   │ A · 管理机       │ WireGuard  │ B 类设备（任意多台）  │
   │ 管理私钥（信任根） │◄═══直连或中继══►│ sshd 仅放行 tailnet │
   │ deploy.py 等     │  密文，不经S │ （公网零暴露）        │
   └─────────────────┘            └───────────────────┘
```

这张图里最重要的一个性质是**控制面与数据面分离**，它决定了各种故障下的表现：

| 情形                | 后果（均实测验证）                                                                  |
| ----------------- | -------------------------------------------------------------------------- |
| S 宕机（headscale 死） | **直连的 A↔B 完全不受影响**——B 本地缓存着通讯录，ssh 照常；只有走中继的流量中断，且保活任务 ≤1 分钟拉起（实测 45~62 秒） |
| A↔B 同局域网          | 直连 ~1ms                                                                    |
| A↔B 跨网/跨国、打洞失败    | 自动走中继：境内 ~20ms、跨境 ~280ms 量级，ssh 命令执行完全可用                                   |

理解了这张图，就可以跑起来了。

## 快速开始

**人工前提**（一次性，无法脚本化）：

1. 云安全组放行：TCP 8443、443；UDP 3478（管理另需 TCP 22/3389，建议限源）
2. 申请一个动态域名（如 DuckDNS，免费）拿到 token
3. A 装有 Python 3 + `pip install paramiko`；Tailscale 客户端（缺失时安装器会提示并可从缓存补装）

**安装（A 上，管理员 PowerShell）：**

```powershell
git clone https://github.com/<you>/tailpet   # 或下载解压
cd tailpet
copy params.example.json params.json         # 填 S 的 IP/用户、域名、token、邮箱（无密码字段）
powershell -ExecutionPolicy Bypass -File install-tailpet.ps1
```

安装器自动完成：程序复制 + PATH 全局命令 → 管理密钥 → A 端 sshd（离线 zip，已装自动跳过）→ 缓存拉取（OpenSSH / Tailscale / Ubuntu rootfs / headscale / acme.sh，直连失败自动走镜像，可配代理）→ 生成 S 离线引导包 `out/S-Bootstrap.zip`。

**部署（新开终端，`tailpet` 已全局可用）：**

```text
1. S-Bootstrap.zip 拷到 S 解压，双击 START-S.bat
   （启用 WSL 需重启 S 一次，重启后再双击一次即完成：装sshd+A公钥+WSL1+Ubuntu+headscale）
2. tailpet bootstrap-s     # 首次接触验证：交互输 S 密码装公钥（仅此一次，密码不落盘）
3. tailpet setup-s         # S 全量部署：headscale+证书+portproxy+防火墙+计划任务+ACL
4. tailpet enroll-a        # A 自己入网
5. tailpet gen-b --zip     # 生成 B 离线安装包 → 拷到 B，双击 START-B.bat 即接入
6. tailpet regression      # 八项回归验收，全 PASS 即成
```

部署完成后的日常，只需要记住两个脚本。

## 日常操作

**A 端——你 99% 的时间只用第一个：**

```powershell
tailpet ssh          # 列出所有 B → 选号回车 → 免密进入（记住各 B 的用户名）
tailpet nodes        # 权威节点表（在线状态/最后在线时间）
tailpet key          # 铸新的 24h 钥匙（接入新 B 用）
tailpet remove <ID>  # 从控制面除名节点
```

**B 端（离线安装包 `tailpet gen-b --zip` 生成，拷到 B 双击 START-B.bat 即接入）**

包内自带日常操作脚本 `tailpet-b.ps1`：`join [-Key 新钥匙] | quit | status | doctor`（重入网 / 退出 / 状态 / 体检）。

**不进交互 shell、只跑一条命令**：`tailpet ssh <节点> "命令"`——底层即 ssh_helper 引擎（PS 目标自动 EncodedCommand，引号/管道/中文免疫；UTF-8→GBK 双回退解码；超时与退出码透传）。独立工具仍在 `lib/ssh_helper.py`。

设备退出的完整语义是两步：B 侧 `quit`（logout，立即失联）+ A 侧 `remove <ID>`（控制面除名）。只 quit 不 remove，节点会一直挂在列表里。

以上是"怎么用"。往下是"为什么这样设计"——理解它们，你才知道哪些环节可以动、哪些是雷。

## 为什么这样设计

| 决策                                                | 原因（多数是踩坑后验证的结论）                                                                                                      |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| 控制面走 **:8443**                                    | 国内部分线路对 443 的 TLS 有按客户端指纹的 RST 干扰，8443 实测全指纹畅通；doctor 会自动探测，你的环境若无干扰可把 control_port 改回 443                           |
| 证书走 **DNS-01**（acme.sh + Let's Encrypt + DuckDNS） | 不依赖入站端口、无人值守续期。HTTP 验证被"国内→80 入站被拦"杀死；TLS-ALPN 被"国际→443 TLS RST"杀死；国内 CA（freessl）又被 DuckDNS 的 CAA 记录缺陷拒签——全试过，只剩这条活路 |
| 计划任务用 **S4U**、headscale **每分钟保活**                 | WSL 发行版按用户注册（SYSTEM 跑不了 wsl），S4U 是免存密码的唯一姿势；WSL1 无 systemd，且**经 ssh 启动的进程会被会话回收**——只有计划任务通道启动的才能常驻；保活含健康探测，假死也能自愈    |
| B 的 sshd **仅放行 tailnet 网段**                       | sshd 零公网暴露，只接受加密网内流量；公网面全黑是这套方案的安全模型                                                                                 |
| **ACL 默认拒绝 + link 白名单**（params `acl`，默认开）        | 节点间访问最小授权：仅 A 基线全通，B→X 的 ssh 须 link 显式放行；策略文件纯 ASCII JSON（PS5.1 编码坑），SIGHUP 热加载不断线；回滚=删 config 的 policy 段重启 |

## 换环境会碰到什么

- **443 指纹干扰**是 ISP/线路行为，非普适——doctor 双端口探测会告诉你答案；两者都被拦（未见过）则需换服务器区域
- **云安全组**是唯一无法从机器内完成的步骤（接云 API 是可做的迭代项）
- headscale 二进制下载走 S 本机代理（脚本默认 `127.0.0.1:10808`），新 S 无代理时改 lib 脚本里的 proxy 变量
- **直连打洞受 NAT 类型限制**：同 NAT 的两台机器打不开洞（hairpin 限制）、A 侧对称型 NAT 时跨网也多走中继——走中继属预期而非故障
- **WSL1 偶发假死**已被健康探测保活覆盖；追求彻底根除可迁移 WSL2 或 Linux 主机（长期建议）
- 升级 headscale：改 setup-s 里的下载 URL；配置模板当前对应 v0.29

## 在现有环境重跑安全吗（幂等性）

上面所有命令都可以重复执行，不会搞坏现有环境：

| 命令                         | 重跑影响                                                   |
| -------------------------- | ------------------------------------------------------ |
| `doctor` / `regression`    | 纯只读                                                    |
| `setup-s`                  | 收敛式：一切已就绪时**零扰动**（逐项跳过）；有差异才动作，配置变更会重启 headscale（~10s） |
| `bootstrap-s` / `enroll-a` | 带保护：前置条件满足时自动跳过（enroll-a 加 `--force` 才强制重认证，有掉线风险勿随意用） |
| `gen-b`                    | 只多铸一把钥匙、生成一个文件                                         |

"安全"不是口号，`regression` 验的就是它——八项：HTTPS 健康+证书受信 / 内嵌中继延迟无告警 / ping B 通 / 免密 ssh / 远程执行 / 节点在线数 / 证书有效期 / 计划任务就绪。`--drills` 再追加三项**破坏性演练**：杀进程自愈、`wsl --shutdown` 自愈、续期脚本实跑——故意搞坏再看它自己爬起来，全部通过，上面这张"重跑安全"的表才算成立。

正文到此。最后附上仓库地图与两份延伸文档——

## 附：仓库地图与延伸阅读

```
tailpet/
├── README.md / CHANGELOG.md / LICENSE(MIT)
├── install-tailpet.ps1        # 安装器（程序+PATH+密钥+A端sshd+缓存+S引导包）
├── tailpet.ps1                # 主 CLI（全局命令 tailpet 的本体）
├── bin/tailpet.cmd            # PATH 垫片
├── deploy.py                  # 部署/回归编排引擎
├── bootstrap/                 # S/B 离线引导包模板（START-*.bat + *-Setup.ps1）
├── lib/                       # 模板与库（headscale 配置 / B 端管理 / acme / 续期 / 保活 / ssh 防坑）
├── out/                       # 生成产物【gitignored】
├── cache/                     # 下载缓存【gitignored】
├── params.example.json        # 参数模板（无密码字段）
├── params.json                # 环境实参【gitignored】
├── docs/                      # 部署日志（公开版）
└── secrets/ archive/          # 私有内容【不入公开仓库】
```
