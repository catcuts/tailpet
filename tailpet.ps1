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

function Invoke-TailpetSsh {
    # 形态1: tailpet ssh            交互选择器
    # 形态2: tailpet ssh <node>      交互登录
    # 形态3: tailpet ssh <node> <cmd...>  远程执行（ssh_helper 语义：PS 目标 EncodedCommand）
    $nodeTok = if ($Rest.Count -ge 1) { "$($Rest[0])" } else { $null }
    $userParam = $null
    for ($i = 1; $i -lt $Rest.Count; $i++) {
        if ("$($Rest[$i])" -eq '-u' -and $i + 1 -lt $Rest.Count) { $userParam = "$($Rest[$i+1])" }
    }
    $cmdParts = @($Rest | Select-Object -Skip 1 | Where-Object { $_ -ne $userParam -and ("$_" -ne '-u') })

    if (-not $nodeTok) {
        $peers = Get-Peers
        if (-not $peers) { Write-Output 'no peers found'; return }
        Write-Output '=== B 类节点 ==='
        for ($i = 0; $i -lt $peers.Count; $i++) {
            Write-Output (('  [{0}] {1}  {2}  ({3})' -f ($i+1), $peers[$i].IP.PadRight(14), $peers[$i].Host.PadRight(18), $peers[$i].State))
        }
        $sel = Read-Host '选择编号回车进入（直接回车取消）'
        if (-not $sel) { return }
        $p = $peers[[int]$sel - 1]
        $u = Get-UserFor $p.IP $userParam
        $input_u = Read-Host "ssh 用户 [默认 $u]"
        if ($input_u) { $u = $input_u }
        Save-UserFor $p.IP $u
        Write-Output ">>> ssh -i <管理钥> $u@$($p.IP)"
        & ssh -i $KEY "$u@$($p.IP)"
        return
    }

    $ip = $null; $hostn = $null
    if ($nodeTok -match '^100\.\d+\.\d+\.\d+$') { $ip = $nodeTok }
    else {
        $nodes = Get-NodesJson
        $n = Resolve-Node $nodeTok $nodes
        if ($n) { $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1); $hostn = $n.name }
    }
    if (-not $ip) { Write-Output "!! 节点未找到: $nodeTok（tailpet nodes 查看）"; return }
    $u = Get-UserFor $ip $userParam

    if ($cmdParts.Count -eq 0) {
        Write-Output ">>> ssh -i <管理钥> $u@$ip"
        & ssh -i $KEY "$u@$ip"
        return
    }

    $cmd = ($cmdParts -join ' ')
    $isPs = $true
    if ($cmd -match '^(whoami|hostname)(&|\s|$)' -or $cmd -match '&\s' -or $cmd -match '/bin/' -or $cmd -match '\bsudo\b' -or $cmd -match '^wsl ') { $isPs = $false }
    if ($isPs) {
        $psScript = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; ' + $cmd
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psScript))
        $wire = 'powershell -NoProfile -EncodedCommand ' + $enc
    } else { $wire = $cmd }
    $out = & ssh -i $KEY -o BatchMode=yes "$u@$ip" $wire 2>&1
    $out | ForEach-Object { "$_" }
    exit $LASTEXITCODE
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
