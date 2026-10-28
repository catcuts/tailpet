# Changelog

## v2.0.1 (2026-10-28)

### C 机 SSH 服务端一键引导（ssh-p 密码模式的前置条件补齐）
- `bootstrap/install-sshd.bat`：纯静态零绑定（无 hub/token/IP/公钥）——自提权（双击友好）→ 解压同目录 OpenSSH-Win64.zip 到 %ProgramFiles%\OpenSSH → 官方 install-sshd.ps1 → 补防火墙放行 22（官方脚本不建规则）→ sshd 设自启并启动（官方脚本留 Manual）→ netstat 自检回显；全离线不联网，2008 R2～Win11 一条路径
- 密码策略：不改任何账号密码——SSH 密码 = 该账号现有 Windows 登录密码；空密码账号本就无法网络登录（脚本末尾给出 `net user administrator *` 引导）
- `tailpet gen-sshd-c`：生成 C 机迷你安装包 `out\sshd-c.zip`（install-sshd.bat + OpenSSH-Win64.zip，~5.4MB），拷到 C 解压双击即装
- agent 包（agent add）同步内嵌 install-sshd.bat；gen-prompt 的 agent 说明补 C 机引导条目

## v2.0.0 (2026-10-20)

架构换轨：headscale / tailscale / WSL / 目标机 sshd 全部退役，改为 **hub（纯标准库 Python）+ 出站长轮询 agent + TCP 中继**。目标机零入站、零安装，兼容 PowerShell 2.0（Server 2008 R2）。

### 新架构
- hub（lib/hub.py）：:8443 命令通道（心跳/长轮询/结果回传/info 上报/metas/cmdset/purge）+ :80 TCP 中继（A/B 两侧出站汇合拼接）
- agent（bootstrap/agent-v2.ps1.template）：PS 2.0 兼容；SYSTEM 计划任务自愈 + 互斥防重 + 隐藏窗口（弹窗风暴根除）；c-aliases 变更上报；agent 端异常上报 hub；中继 worker 按需拉起
- tailpet tunnel 走中继：本机浏览器打开 B 及其内网任意 TCP（HTTP/HTTPS/WebSocket 透明，实测 ~35ms）；同目标去重复用；第 4 参数可指定 B 内网目标 IP
- 命令面收敛：agent add/exec/list/rm、ssh、nodes、tunnel、sync-alias、gen-prompt、machine；退役 v1 的 status/key/link/rename/remove/setup-s/gen-b 等

### B → 内网 C 机（OpenSSH 内嵌）
- agent 安装包内嵌离线 OpenSSH 客户端（v1 缓存复用，2008 R2 实测可用）：装完即有 `ssh-c`，`tailpet agent exec 公司B "ssh-c user@C_IP 命令"` 直达 C 机
- 密钥自动生成（ed25519，ACL 收紧至 SYSTEM+Administrators），公钥随心跳上报 hub（/metas 的 pubkey 字段）
- `tailpet file get/put/list`：文件经 hub 分块中转（256KB 分块、SHA-256、异步解耦——B 传完即可离线，A 随时取；实测 10MB/~16s，速率取决于站点上行）

### 体验与健壮
- `tailpet agent add` 幂等升级：同名复用 id/token 按当前模板重新打包（已部署 B 无缝升级，不断线不产生幽灵）
- Add-Agent 重跑自动接管：结束旧常驻实例再启动，杜绝"磁盘新码、内存旧码"
- exec 链路：120 秒硬超时（杀进程树）、精确退出码（独立标记文件 + cmd /V:ON 延迟展开）、BatchMode 防挂起、命令引号自动剥壳
- gen-prompt：引导先探测远程 PowerShell 版本（Get-Host）+ 转义/编码避坑（EncodedCommand / GBK / 不要 chcp 65001）
- 全视图 CJK 宽度感知对齐（中文按 2 列），agent list / nodes / gen-prompt / machine list / tunnel-list / help 统一
- 状态 emoji 化：🌍online / 🚫offline，一眼区分
- 全视图统一排序：在线优先 → 组内按名
- agent list / nodes / gen-prompt 增 VER 列：agent 版本号随心跳上报，`-` 即待升级
- `tailpet tunnel-list`：查看活动隧道，失联记录自动清理

### 管理页面
- `tailpet web [-p 端口] [-d]`：本机 Web 控制台（web.py，纯标准库）——机器列表/命令下发/隧道管理/文件取回推送/安装包生成下载；危险操作二次确认；自动刷新间隔与下载目录页面可配（下一轮生效）；前台 Ctrl+C 或后台 `tailpet web-stop`；防重复启动

### 实战反馈修复（沐川站点一线使用报告）
- `-c`/`-C` 参数被吞（grep -c/ssh -c 全中招）：tailpet.ps1 移除 param 块改 $args 裸收——PowerShell 参数缩写绑定会把 -c 匹配成 -Cmd
- `file put` 挂死修复（双根因）：filedone 先删分块致 worker 404（改顺序）；hub 404 响应无 Content-Length 致 keep-alive 客户端无限等待（补 CL+close）
- `ssh-p` 密码模式 SSH：现场 C 机没装公钥是常态——plink（全 Windows 兼容，含 2008 R2）+ ssh-keyscan 现取公钥 TOFU + `-pw` 密码，零预装零提示；win-sshpass 因 Go 构建在 2008 R2 启动即挂死而弃用
- gen-prompt 命令规则补录：长度上限 8K、管道符拆坏、&& 不可串联 ssh、密码特殊字符用 EncodedCommand
- Git Bash shim（bin/tailpet）：绕过 cmd 层，&&/引号语义正常
- agent 版本号上报（ver 字段）+ 三视图 VER 列：`-` 即待升级

### 关键修复（v2 开发期实战）
- hub /poll 对自身 cmd.b64 做 JSON 解析导致命令永不投递 + mtime 判定使两轮询间到达的命令卡死
- agent 模板 $calUrl 未定义 → c-aliases 一出现即崩溃死循环（agent 失联 17h 的根因）
- 打包 ASCII 编码致中文机器名变 ??
- PowerShell `$p` 循环变量覆盖参数对象 `$P`（大小写不敏感）
- PS 5.1 `Get-Date -UFormat %s` 按本地时间算 epoch（+8h，在线状态恒 offline）
- cmd /c 重定向只覆盖 && 链末段 → 临时 bat 承载 + @echo off
- purge 缺 body 400、重复函数定义遮蔽、列表列错位
- v1.0.0 条目见下（历史）


## v1.0.0 (2026-10-06)

首个正式版本。由 2026-09-29 起的真实环境部署实战提炼，全部能力均经生产验证。

### 核心
- 一键部署编排（doctor / bootstrap-s / setup-s / enroll-a / gen-b / regression）
- 证书：Let's Encrypt + DuckDNS DNS-01，全自动续期，不依赖入站端口
- 计划任务 S4U 化（零密码存储）+ 每分钟健康探测保活
- ACL：默认拒绝 + link 白名单（节点间 ssh 显式授权，热加载）
- 节点自定义命名（rename / --hostname，全网同步显示）

### v1.0 产品化
- 全局命令 `tailpet`（安装器 + PATH + cmd 垫片）
- `tailpet ssh <节点> [命令...]`：ID/名/IP 直达 + 远程执行（PS EncodedCommand / GBK 双解码）
- S/B 离线安装包（自提权 .bat + 全依赖内置，S 与 B 零 GitHub 依赖；B 侧钥匙过期自动中止）
- A 中转下载体系（fetch 缓存 + 镜像回退，A 是唯一可能走代理的机器）

### 已知边界
- 国内部分线路对 443 的 TLS 有指纹 RST 干扰 → 控制面统一 :8443（doctor 自动判定）
- WSL1 偶发假死由健康探测保活覆盖；长期建议迁移 WSL2/Linux
