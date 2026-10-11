# tailpet - 自建组网管理器（S 控制面 / A 管理机 / B 现场设备）
# 用法: tailpet <命令> [参数...]   （tailpet help 查看全部）
param(
    [string]$Cmd = 'help',
    [Parameter(ValueFromRemainingArguments = $true)]$Rest
)

$ErrorActionPreference = 'Continue'
$pkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$P = Get-Content (Join-Path $pkgDir 'params.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$TS  = $P.a.tailscale_exe
$KEY = $P.a.ssh_key
$SSH_S = @('-i', $KEY, '-o', 'BatchMode=yes', "$($P.server.user)@$($P.server.host)")
$HS  = "wsl -d $($P.server.wsl_distro) -u root headscale --config /etc/headscale/config.yaml"

# ============ 基础设施 ============
function Invoke-OnS([string]$cmd) {
    $out = & ssh @SSH_S ("[Console]::OutputEncoding=[Text.Encoding]::UTF8; " + $cmd) 2>$null
    return ($out -join "`n")
}

function Get-NodesJson {
    $json = Invoke-OnS ($HS + ' nodes list -o json')
    if (-not $json) { return $null }
    return ($json | ConvertFrom-Json)
}

function Get-MyNodeId {
    $myip = (& $TS ip -4 2>$null | Select-Object -First 1)
    $nodes = Get-NodesJson
    foreach ($n in $nodes) { if ((@($n.ip_addresses) -contains $myip)) { return [int]$n.id } }
    return 0
}

# ============ 日常：节点管理 ============
function Do-Nodes {
    $nodes = Get-NodesJson
    if (-not $nodes) { Write-Output 'failed to query headscale on S'; return }
    Write-Output ('{0,-4} {1,-30} {2,-14} {3,-8} {4}' -f 'ID', 'NAME (HOSTNAME)', 'IP', 'ONLINE', 'LAST SEEN')
    foreach ($n in $nodes) {
        $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        $seen = if ($n.last_seen.seconds) { [DateTimeOffset]::FromUnixTimeSeconds($n.last_seen.seconds).LocalDateTime.ToString('MM-dd HH:mm') } else { '-' }
        $disp = if ($n.given_name) { $n.given_name + ' (' + $n.name + ')' } else { $n.name }
        Write-Output ('{0,-4} {1,-30} {2,-14} {3,-8} {4}' -f $n.id, $disp, $ip, ([bool]$n.online), $seen)
    }
}

function Do-Status { & $TS status }

function Do-Key {
    $out = Invoke-OnS ($HS + ' preauthkeys create --user 1 --expiration 24h --reusable')
    if ($out -match '(hskey-auth-\S+)') {
        Write-Output ('fresh preauth key (24h, reusable): ' + $Matches[1])
        Write-Output 'usage: tailpet gen-b --zip 生成含新钥匙的 B 离线安装包'
    } else { Write-Output ('mint failed: ' + $out) }
}

function Do-Rename([string]$id, [string]$name) {
    if (-not $id -or -not $name) { Write-Output 'usage: tailpet rename <nodeID> <newName>'; return }
    $out = Invoke-OnS ($HS + ' nodes rename ' + $name + ' -i ' + $id + ' --force')
    Write-Output $out
    Do-Nodes
}

function Do-Remove([string]$id) {
    if (-not $id) { Write-Output 'usage: tailpet remove <nodeID>'; return }
    $out = Invoke-OnS ($HS + ' nodes delete -i ' + $id + ' --force')
    Write-Output $out
    Do-Nodes
}

# ============ 日常：ACL link/unlink ============
function Get-Policy {
    $raw = Invoke-OnS ("wsl -d " + $P.server.wsl_distro + " -u root cat /etc/headscale/acl.hujson")
    if (-not $raw) { return $null }
    $clean = ($raw -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    return ($clean | ConvertFrom-Json)
}

function Set-Policy([psobject]$policyObj) {
    $json = ConvertTo-Json $policyObj -Depth 6
    $tmp = Join-Path $env:TEMP 'acl_push.json'
    [IO.File]::WriteAllText($tmp, $json, [Text.Encoding]::ASCII)
    Get-Content $tmp -Raw | ssh @SSH_S "wsl -d $($P.server.wsl_distro) -u root bash -c 'cat > /etc/headscale/acl.hujson'"
    Invoke-OnS ("wsl -d " + $P.server.wsl_distro + " -u root pkill -HUP -x headscale") | Out-Null
    Start-Sleep 2
    Write-Output '(policy reloaded)'
}

function Resolve-Node([string]$token, $nodes) {
    foreach ($n in $nodes) {
        if ("$($n.id)" -eq $token -or $n.given_name -ieq $token -or $n.name -ieq $token) { return $n }
        if ((@($n.ip_addresses) -contains $token)) { return $n }
    }
    return $null
}

function Rebuild-With-Links($nodes, $linkRules) {
    $hosts = [ordered]@{}
    foreach ($n in $nodes) {
        $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        if ($ip) { $hosts["n$($n.id)"] = "$ip/32" }
    }
    $myid = Get-MyNodeId
    $acls = @()
    if ($myid -gt 0) { $acls += [ordered]@{ action = 'accept'; src = @("n$myid"); dst = @('*:*') } }
    foreach ($r in $linkRules) { $acls += $r }
    return [ordered]@{ hosts = $hosts; acls = $acls }
}

function Show-Links($policy) {
    Write-Output 'current links (src -> dst:22):'
    $any = $false
    foreach ($r in @($policy.acls)) {
        if (@($r.dst)[0] -ne '*:*') {
            Write-Output ('  ' + (@($r.src)[0]) + ' -> ' + (@($r.dst)[0]))
            $any = $true
        }
    }
    if (-not $any) { Write-Output '  (none)' }
}

function Do-Link([string]$srcTok, [string]$dstTok, [switch]$Remove) {
    $nodes = Get-NodesJson
    if (-not $nodes) { return }
    $src = Resolve-Node $srcTok $nodes
    $dst = Resolve-Node $dstTok $nodes
    if (-not $src -or -not $dst) { Write-Output '!! src/dst 未找到（tailpet nodes 查看可用 ID/名称/IP）'; return }
    $myid = Get-MyNodeId
    if ([int]$src.id -eq $myid) { Write-Output '!! A 是管理根（基线已全通），不能作为 link 的源'; return }
    $rule = [ordered]@{ action = 'accept'; src = @("n$($src.id)"); dst = @("n$($dst.id):22") }
    $policy = Get-Policy
    $links = @()
    foreach ($r in @($policy.acls)) { if (@($r.dst)[0] -ne '*:*') { $links += $r } }
    $exists = $false
    $kept = @()
    foreach ($r in $links) {
        if ((@($r.src)[0] -eq $rule.src[0]) -and (@($r.dst)[0] -eq $rule.dst[0])) { $exists = $true }
        else { $kept += $r }
    }
    if ($Remove) {
        if (-not $exists) { Write-Output "!! 规则不存在: n$($src.id) -> n$($dst.id):22"; return }
        $links = $kept
        Write-Output "removed: n$($src.id)($($src.given_name)) -> n$($dst.id):22"
    } else {
        if ($exists) { Write-Output "已存在，无需重复: n$($src.id) -> n$($dst.id):22"; Show-Links $policy; return }
        $links = $links + $rule
        Write-Output "added: n$($src.id)($($src.given_name)) -> n$($dst.id)($($dst.given_name)):22"
    }
    $newPolicy = Rebuild-With-Links $nodes $links
    Set-Policy $newPolicy
    Show-Links (Get-Policy)
}

function Do-Links {
    $policy = Get-Policy
    if ($policy) { Show-Links $policy } else { Write-Output '!! S 上无策略文件（ACL 未启用？）' }
}

# ============ 日常：ssh ============
function Get-Peers {
    $lines = & $TS status 2>$null | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+\s+\S+' }
    $self = (& $TS ip -4)
    $peers = @()
    foreach ($l in $lines) {
        $parts = $l -split '\s+', 5
        if ($parts[0] -eq $self) { continue }
        $peers += [pscustomobject]@{ IP = $parts[0]; Host = $parts[1]; State = ($parts[4] -replace '\s+', ' ') }
    }
    return $peers
}

function Get-UserFor([string]$ip, [string]$userParam) {
    if ($userParam) { return $userParam }
    $memoFile = Join-Path $pkgDir '.ssh_last.json'
    $memo = @{}
    if (Test-Path $memoFile) { $memo = Get-Content $memoFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
    if ($memo[$ip]) { return $memo[$ip] }
    return 'administrator'
}

function Save-UserFor([string]$ip, [string]$u) {
    $memoFile = Join-Path $pkgDir '.ssh_last.json'
    $memo = @{}
    if (Test-Path $memoFile) { $memo = Get-Content $memoFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
    $memo[$ip] = $u
    $memo | ConvertTo-Json | Set-Content $memoFile -Encoding UTF8
}


# ============ 本地机器注册表 ============
$MachinesFile = Join-Path $pkgDir '.machines.json'

function Get-Machines {
    if (Test-Path $MachinesFile) {
        $raw = Get-Content $MachinesFile -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -is [array]) { return $parsed } else { return @($parsed) }
    }
    return @()
}

function Set-Machines($machines) {
    $machines | ConvertTo-Json -Depth 3 | Set-Content $MachinesFile -Encoding UTF8
}

function Do-MachineAdd([string]$name, [string]$ip, [string]$user, [string]$type, [string]$jump) {
    if (-not $name -or -not $ip) {
        Write-Output 'usage: tailpet machine add <name> <ip> [-user u] [-type pub|lan] [-jump B名]'
        Write-Output '  type: pub=公网直连, lan=C类(经B跳板); jump 仅 type=lan 时需要'
        return
    }
    if (-not $user) { $user = 'administrator' }
    if (-not $type) { $type = 'pub' }
    if ($type -eq 'lan' -and -not $jump) { Write-Output '!! type=lan 需要指定 -jump <B名>'; return }
    $machines = @(Get-Machines)
    $exists = $machines | Where-Object { $_.name -ieq $name }
    if ($exists) { Write-Output "!! 已存在同名机器: $name"; return }
    $machines += [pscustomobject]@{ name = $name; ip = $ip; user = $user; type = $type; jump = $jump }
    Set-Machines $machines
    Write-Output "added: $name ($ip, $type$(if ($jump) { ', jump=' + $jump }))"
}

function Do-MachineRemove([string]$name) {
    if (-not $name) { Write-Output 'usage: tailpet machine remove <name>'; return }
    $machines = @(Get-Machines)
    $kept = @($machines | Where-Object { $_.name -ne $name })
    if ($kept.Count -eq $machines.Count) { Write-Output "!! 未找到: $name"; return }
    Set-Machines $kept
    Write-Output "removed: $name"
}

function Do-MachineList {
    $machines = Get-Machines
    if (-not $machines -or $machines.Count -eq 0) { Write-Output '(注册表为空 — tailpet machine add 添加)'; return }
    Write-Output ('{0,-20} {1,-16} {2,-16} {3,-6} {4}' -f 'NAME', 'IP', 'USER', 'TYPE', 'JUMP')
    for ($i = 0; $i -lt $machines.Count; $i++) {
        $m = $machines[$i]
        Write-Output ('{0,-20} {1,-16} {2,-16} {3,-6} {4}' -f "$($m.name)", "$($m.ip)", "$($m.user)", "$($m.type)", "$($m.jump)")
    }
}

# ============ gen-prompt ============
function Do-GenPrompt {
    # 构建合并列表：tailnet 节点（实时）+ 本地注册表
    $items = @()

    # tailnet 节点
    $peers = Get-Peers
    foreach ($p in $peers) {
        $items += [pscustomobject]@{
            Label = "$($p.Host)  $($p.IP.PadRight(14)) (tailnet)"
            Type = 'tailnet'; IP = $p.IP; Name = $p.Host; User = $null; Jump = $null
        }
    }

    # 注册表机器
    $machines = @(Get-Machines)
    foreach ($m in $machines) {
        $typeLabel = if ($m.type -eq 'lan') { "C类,经$($m.jump)" } else { $m.type }
        $items += [pscustomobject]@{
            Label = "$($m.name.PadRight(18)) $($m.ip.PadRight(16)) ($typeLabel)"
            Type = $m.type; IP = $m.ip; Name = $m.name; User = $m.user; Jump = $m.jump
        }
    }

    # 新建选项
    $items += [pscustomobject]@{
        Label = '新建...'; Type = 'new'; IP = $null; Name = $null; User = $null; Jump = $null
    }

    Write-Output '=== 生成连接信息 ==='
    for ($i = 0; $i -lt $items.Count; $i++) {
        Write-Output ('  [{0}] {1}' -f ($i+1), $items[$i].Label)
    }
    $sel = Read-Host '选择编号（直接回车取消）'
    if (-not $sel) { return }
    $item = $items[[int]$sel - 1]

    if ($item.Type -eq 'new') {
        $item = New-MachineInteractive
        if (-not $item) { return }
        # 保存到注册表
        $machines = @(Get-Machines)
        $machines += [pscustomobject]@{ name = $item.Name; ip = $item.IP; user = $item.User; type = $item.Type; jump = $item.Jump }
        Set-Machines $machines
        Write-Output "(已保存到注册表: $($item.Name))"
    }

    # 询问用户名（如果有默认则提示）
    if (-not $item.User) { $item.User = 'administrator' }
    $inputU = Read-Host "SSH 用户 [默认 $($item.User)]"
    if ($inputU) { $item.User = $inputU }

    # 生成文本
    $text = Build-PromptText $item

    Write-Output ''
    Write-Output '==================== 生成的连接信息 ===================='
    Write-Output $text
    Write-Output '========================================================='
    try {
        Set-Clipboard -Value $text
        Write-Output '(已复制到剪贴板)'
    } catch { Write-Output '(剪贴板复制失败 — 请手动复制上方文本)' }
}

function New-MachineInteractive {
    Write-Output '机器类型:'
    Write-Output '  [1] 公网直连（有公网 IP，不入 tailnet）'
    Write-Output '  [2] C 类（同网段，经 B 跳板）'
    $t = Read-Host '选择'
    if ($t -eq '1') {
        $ip = Read-Host '公网 IP'
        $name = Read-Host '名称（如 web-server）'
        $user = Read-Host 'SSH 用户 [administrator]'
        if (-not $user) { $user = 'administrator' }
        return [pscustomobject]@{ Type = 'pub'; IP = $ip; Name = $name; User = $user; Jump = $null }
    } elseif ($t -eq '2') {
        $peers = Get-Peers
        Write-Output '跳板 B 是哪台?'
        for ($i = 0; $i -lt $peers.Count; $i++) {
            Write-Output ('  [{0}] {1}' -f ($i+1), $peers[$i].Host)
        }
        $jsel = Read-Host '选择'
        $jump = $peers[[int]$jsel - 1].Host
        $ip = Read-Host 'C 的 LAN IP'
        $name = Read-Host '名称（如 c-behind-sg）'
        $user = Read-Host 'C 的 SSH 用户'
        return [pscustomobject]@{ Type = 'lan'; IP = $ip; Name = $name; User = $user; Jump = $jump }
    }
    return $null
}

function Build-PromptText($item) {
    $keyPath = '~/.ssh/id_ed25519_voerka'
    $lines = @()

    if ($item.Type -eq 'tailnet') {
        $lines += '## B 机连接信息：' + $item.Name
        $lines += '- **Tailnet IP**: ' + $item.IP
        $lines += '- **SSH 用户**: ' + $item.User
        $lines += '- **SSH 密钥**: ' + $keyPath
        $lines += '- **连接**:'
        $lines += '  - `tailpet ssh ' + $item.Name + '`（交互进入）'
        $lines += '  - `tailpet ssh ' + $item.Name + ' "命令"`（远程执行，支持 PowerShell 语法）'
        $lines += '  - `ssh -i ' + $keyPath + ' ' + $item.User + '@' + $item.IP + '`'
        $lines += '- **系统**: Windows'
        $lines += '- **注意**: 远程执行 PS 命令建议用 EncodedCommand 避免转义；中文输出按 GBK 解码'
    }
    elseif ($item.Type -eq 'pub') {
        $lines += '## 公网直连机器：' + $item.Name
        $lines += '- **公网 IP**: ' + $item.IP
        $lines += '- **SSH 用户**: ' + $item.User
        $lines += '- **SSH 密钥**: ' + $keyPath
        $lines += '- **连接**: `ssh -i ' + $keyPath + ' ' + $item.User + '@' + $item.IP + '`'
        $lines += '- **注意**: Windows 系统；远程执行 PS 命令建议用 EncodedCommand'
    }
    elseif ($item.Type -eq 'lan') {
        $lines += '## C 机连接信息：' + $item.Name + '（经 ' + $item.Jump + ' 跳板）'
        $lines += '- **跳板 B**: ' + $item.Jump
        $lines += '- **C 的 LAN IP**: ' + $item.IP
        $lines += '- **C 的 SSH 用户**: ' + $item.User
        $lines += '- **连接**:'
        $lines += '  1. 先进 B：`tailpet ssh ' + $item.Jump + '`'
        $lines += '  2. 再进 C：`ssh ' + $item.User + '@' + $item.IP + '`（B 上有默认密钥，免密直达）'
        $lines += '- **注意**: C 不入 tailnet；C 必须有密码的 Windows 账户'
    }
    return ($lines -join "`n")
}

# ============ 部署/维护：封装 deploy.py ============
function Invoke-Deploy {
    $pyargs = @($Cmd) + @($Rest | ForEach-Object { "$_" })
    & python (Join-Path $pkgDir 'deploy.py') @pyargs
    exit $LASTEXITCODE
}

function Show-Help {
Write-Output @'
tailpet v1.0 —— 自建组网管理器（S 控制面 / A 管理机 / B 现场设备）

日常：
  tailpet ssh                     交互式选 B 进入
  tailpet ssh <节点> [命令...]     远程执行（无命令=交互登录；节点=ID/名/100.x IP）
  tailpet nodes                   节点表（ID/名称/IP/在线/最后在线）
  tailpet status                  本地 tailscale 状态
  tailpet key                     铸 24h 入网钥匙
  tailpet link <源> <目标>         允许源节点 ssh 目标节点
  tailpet unlink <源> <目标>      解除授权
  tailpet links                   查看授权表
  tailpet rename <id> <名>        节点改名
  tailpet remove <id>             节点除名

机器管理：
  tailpet gen-prompt              交互式生成连接信息（自动复制到剪贴板）
  tailpet machine list            查看本地机器注册表
  tailpet machine add <名> <IP> [-u 用户] [-t pub|lan] [-j 跳板B]
  tailpet machine remove <名>     从注册表删除

部署：
  tailpet make-s-zip              生成 S 离线引导包（out/S-Bootstrap.zip）
  tailpet gen-b [--zip]           生成 B 脚本（--zip=离线安装包 out/B-Bootstrap-<日期>.zip）
  tailpet bootstrap-s             首次接触验证（交互输 S 密码装公钥）
  tailpet setup-s                 S 全量部署
  tailpet enroll-a                A 入网（幂等）

维护：
  tailpet doctor                  预检 + 网络探测
  tailpet regression [--drills]   八项回归验收
'@
}

# ============ 分发 ============
switch ($Cmd.ToLower()) {
    'ssh'      { Invoke-TailpetSsh }
    'nodes'    { Do-Nodes }
    'status'   { Do-Status }
    'key'      { Do-Key }
    'rename'   { Do-Rename "$($Rest[0])" "$($Rest[1])" }
    'remove'   { Do-Remove "$($Rest[0])" }
    'link'     { Do-Link "$($Rest[0])" "$($Rest[1])" }
    'unlink'   { Do-Link "$($Rest[0])" "$($Rest[1])" -Remove }
    'links'    { Do-Links }
    'gen-prompt'   { Do-GenPrompt }
    'machine'      {
        $sub = "$($Rest[0])"
        switch ($sub) {
            'add'    { Do-MachineAdd "$($Rest[1])" "$($Rest[2])" "$($Rest[3])" "$($Rest[4])" "$($Rest[5])" }
            'remove' { Do-MachineRemove "$($Rest[1])" }
            'list'   { Do-MachineList }
            default  { Do-MachineList }
        }
    }
    'make-s-zip'   { Invoke-Deploy }
    'gen-b'        { Invoke-Deploy }
    'bootstrap-s'  { Invoke-Deploy }
    'setup-s'      { Invoke-Deploy }
    'enroll-a'     { Invoke-Deploy }
    'doctor'       { Invoke-Deploy }
    'regression'   { Invoke-Deploy }
    'help'         { Show-Help }
    default        { Show-Help }
}
