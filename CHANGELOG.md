# Changelog

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
