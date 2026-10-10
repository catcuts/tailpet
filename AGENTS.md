# AGENTS.md — AI 会话接手指引

> 任何 AI 会话（Claude/ZCode/其他）开始工作前先读本文件。人类用户可忽略。

## 这个项目是什么

**tailpet**：自建 Headscale/Tailscale 组网的部署·管理·回归工具集。一台公网 Windows 服务器（S）+ 一台管理机（A）+ 任意多台现场设备（B）组成 WireGuard 加密网，A 可对任意 B 免密远程执行命令。

- 开源地址：https://github.com/catcuts/tailpet（MIT）
- 完整使用手册：`README.md`
- 全程时间线（所有坑与决策）：`docs/部署日志.md`
- **环境交接（含真实凭据，勿外传）**：`docs/环境交接.md`

## 双仓格局（重要）

| 仓库 | 路径 | 用途 | 推送目标 |
|---|---|---|---|
| 私有仓 | `H:\project\tailpet` | 全量开发（含 docs 凭据、archive、params.json） | 不推送 |
| 公开仓镜像 | `H:\project\tailpet-public` | 只含代码+通用文档（全新干净历史） | `github.com/catcuts/tailpet` |

**规则**：
1. 日常开发/修改在**私有仓**进行
2. 需要发布时：从私库拷白名单文件到公开库 → 提交（作者 `24911463+catcuts@users.noreply.github.com`）→ push
3. **绝不能直接 push 私有仓**——其 git 历史含真实凭据（旧版 cert_renew.sh 的 DuckDNS token、部署日志里的 IP/密码等）
4. 公开库同步白名单：`README.md CHANGELOG.md LICENSE install-tailpet.ps1 tailpet.ps1 bin/ deploy.py bootstrap/ lib/ params.example.json`

## 当前生产环境速览

| 角色 | 机器 | 状态 |
|---|---|---|
| S | 腾讯云 Windows（IP/domain 见 params.json） | headscale v0.29.4 + :8443 portproxy + ACL + 证书自动续期，运行中 |
| A | 本机（desktop-j0ouoe2，节点 a-main / 100.64.0.1） | tailpet 已安装（`%LOCALAPPDATA%\tailpet`），全局命令可用 |
| B1 | 楼内 desktop-ujgteqk（100.64.0.2） | 已入网，常离线（测试机） |
| B2 | 新加坡 desktop-ijohqp2 / sg-b01（100.64.0.3） | 已入网，云上常开 |

## 关键操作入口（A 机）

```powershell
tailpet                     # 帮助
tailpet nodes / links       # 节点表 / ACL 授权表
tailpet ssh                 # 交互式选 B 进入
tailpet ssh <节点> "命令"    # 远程执行
tailpet regression          # 八项回归验收
python H:\project\tailpet\deploy.py <子命令>   # 开发态直接调引擎
```

已安装的运行副本在 `%LOCALAPPDATA%\tailpet`（开发改的是 `H:\project\tailpet`，改完要重新跑 install-tailpet.ps1 才反映到全局命令）。

## 已踩过的坑（新会话必读，防重蹈）

1. **PS 5.1 编码**：任何含中文的 .ps1 必须存 **UTF-8 with BOM**（utf-8-sig），否则按 GBK 误读导致语法崩溃；策略/配置文件传 SSH 管道一律纯 ASCII
2. **heredoc 转义**：往 python 里灌含 `$`、`\n`、引号的多行内容，bash heredoc 会咬字——一律走 Write 工具落盘 .py 再执行
3. **WSL1 进程生命周期**：headscale 只能经计划任务通道启动/恢复（`schtasks /run /tn Headscale-Keepalive`）；ssh 会话内 nohup 启动的会被回收
4. **schtasks /ri 对 onstart 任务无效**：重复任务必须 `/sc minute /mo 1` 单独建
5. **GitHub React 表单**：`button.click()` 可能触发 What?! 错误页，改用 `form.submit()`
6. **443 TLS 指纹干扰**：国内部分线路对 443 有按客户端指纹的 RST；控制面统一走 :8443（portproxy）
7. **headscale v0.29.4 的 release 资产名不带 .tar.gz**，是裸 ELF 二进制直接 install

## 已安装副本同步（易忘）

开发仓改动     后，必须同步已安装副本（否则 PATH 里的 tailpet 用旧模板）：


## 红线（不能做）

- 不 push 私有仓到任何远端
- 不把 `docs/`、`secrets/`、`archive/`、`params.json`、`cache/`、`out/` 加入公开库
- 不删除/重启 B2（新加坡，生产验证机）未经用户确认
- 不改动 S 上 `/etc/headscale/config.yaml` 的 `policy:` 段除非用户明确要求
- 银行/身份等敏感个人信息不代填

## CPS 推广

腾讯云推广大使（个人实名，返佣 20-35%），专属 cps_key 已嵌入 README 购买推荐节。收款银行信息由用户自行在 [控制台](https://console.cloud.tencent.com/spread) 完善。

## 会话交接协议

新会话开工前按顺序读：本文件 → `README.md` → `docs/部署日志.md`（最新几节）→ 如涉及现网操作再读 `docs/环境交接.md`。改完东西：私有仓提交；若需发布，同步公开库并推送。部署日志**随时追加**——它是跨会话的主要记忆。
