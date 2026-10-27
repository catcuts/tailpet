# tailpet - 自建组网管理器（S 控制面 / A 管理机 / B 现场设备）
# 用法: tailpet <命令> [参数...]   （tailpet help 查看全部）
# 无 param 块：所有参数原样进 $args——参数名缩写绑定（-c 匹配 -Cmd 等）曾把用户命令里的
# 旗标吃掉导致命令静默变形（grep -c / ssh -c 全踩过），普通 $args 不做任何绑定
$Cmd = [string]$args[0]
if (-not $Cmd) { $Cmd = 'help' }
$Rest = @($args | Select-Object -Skip 1)

$ErrorActionPreference = 'Continue'
$pkgDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$P = Get-Content (Join-Path $pkgDir 'params.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$TS  = $P.a.tailscale_exe
$KEY = $P.a.ssh_key
$SSH_S = @('-i', $KEY, '-o', 'BatchMode=yes', "$($P.server.user)@$($P.server.host)")
$HS  = "wsl -d $($P.server.wsl_distro) -u root headscale --config /etc/headscale/config.yaml"

# ============ 基础设施 ============
function Invoke-OnS([string]$cmd) {
    $out = & ssh @SSH_S ("[Console]::OutputEncoding=[Text.Encoding]::UTF8; " + $cmd) 2>&1
    return ($out -join "`n")
}

function Get-NodesJson {
    # ssh 偶发抖动（kex_exchange_identification）会污染输出导致解析失败，重试一次
    foreach ($attempt in 1..2) {
        $json = Invoke-OnS ($HS + ' nodes list -o json')
        try {
            $parsed = $json | ConvertFrom-Json
            if ($parsed) {
                if ($parsed -is [array]) { return $parsed } else { return @($parsed) }
            }
        } catch { }
        if ($attempt -eq 1) { Start-Sleep 2 }
    }
    return $null
}

function Get-MyNodeId {
    $myip = (& $TS ip -4 2>$null | Select-Object -First 1)
    $nodes = Get-NodesJson
    foreach ($n in $nodes) { if ((@($n.ip_addresses) -contains $myip)) { return [int]$n.id } }
    return 0
}

# ============ 日常：节点管理 ============
function Get-MachineRows([switch]$ExcludeSelf) {
    # 统一行构建（nodes 表与 ssh 选择器共用）：先同步别名（含改名检查，只对在线节点 ssh），
    # 再按 A→B→C 拓扑出统一行集。NAME=别名优先，无别名显示主机名；lan 缩进挂其 B 下
    $changeLog = New-Object System.Collections.ArrayList
    $spin = -not [Console]::IsOutputRedirected   # 管道/捕获时不显示动画（\r 会污染输出流）
    if ($spin) { Write-Host -NoNewline '同步别名中...' }
    Do-SyncAlias -Quiet $changeLog
    if ($spin) { Write-Host -NoNewline ("`r" + (' ' * 30) + "`r") }
    # 查询失败是常态：网内行为空，agent/pub 照常
    $nodes = @()
    try { $nodes = @(Get-NodesJson) } catch { $nodes = @() }
    if (-not $nodes) { $nodes = @() }
    $allMachines = @(Get-Machines)
    $aliasByIp = @{}
    foreach ($m in $allMachines) {
        if ($m.type -eq 'tailnet') { $aliasByIp[$m.ip] = $m.name }
    }
    $myip = (& $TS ip -4 2>$null | Select-Object -First 1)
    $rows = @()
    $matchedLan = @{}
    $num = 0
    # agent 机器（反向隧道经 S）：先列，其身后的 lan 挂树
    foreach ($m in ($allMachines | Where-Object { $_.type -eq 'agent' })) {
        $num++
        $rows += [pscustomobject]@{ Num = $num; Name = $m.name; IP = $m.ip; Type = 'agent'; Online = '-'; Seen = '-'; Token = $m.name; User = $m.user; Jump = $m.jump; Ver = '-' }
        $cs = @($allMachines | Where-Object { $_.type -eq 'lan' -and $_.jump -eq $m.jump })
        foreach ($c in $cs) {
            $matchedLan[$c.name] = $true
            $num++
            $rows += [pscustomobject]@{ Num = $num; Name = ('  ' + $c.name); IP = $c.ip; Type = 'lan'; Online = '-'; Seen = '-'; Token = $c.name; User = $c.user; Jump = $c.jump; Ver = '-' }
        }
    }
    # V2 agent 机器：以 hub 为准（心跳自动注册），registry agent 条目兼容保留
    $metas = Get-AgentMetas
    if ($metas) {
        $nowTs = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        $hubRows = @()
        foreach ($kv in $metas.PSObject.Properties) {
            $hm = $kv.Value
            if ($allMachines | Where-Object { $_.type -eq 'agent' -and $_.name -ieq $hm.name }) { continue }
            $hseen = if ($hm.lastSeen) { [DateTimeOffset]::FromUnixTimeSeconds([long]$hm.lastSeen).LocalDateTime.ToString('MM-dd HH:mm') } else { '-' }
            $ison = [bool]($hm.lastSeen -and ($nowTs - [long]$hm.lastSeen) -lt 90)
            $hon = if ($ison) { '🌍online' } else { '🚫offline' }
            $hubRows += [pscustomobject]@{ Name = $hm.name; IP = $hm.ip; Type = 'agent'; Online = $hon; Seen = $hseen; Token = $hm.name; User = 'administrator'; Jump = ('hub:' + $kv.Name); Ver = $(if ($hm.ver) { $hm.ver } else { '-' }); Orank = $(if ($ison) { 0 } else { 1 }) }
        }
        foreach ($r in ($hubRows | Sort-Object -Property Orank, Name)) {
            $num++
            $rows += [pscustomobject]@{ Num = $num; Name = $r.Name; IP = $r.IP; Type = 'agent'; Online = $r.Online; Seen = $r.Seen; Token = $r.Token; User = $r.User; Jump = $r.Jump; Ver = $r.Ver }
        }
    }
    foreach ($n in $nodes) {
        $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        if (-not $ip -or ($ExcludeSelf -and $ip -eq $myip)) { continue }
        $seen = if ($n.last_seen.seconds) { [DateTimeOffset]::FromUnixTimeSeconds($n.last_seen.seconds).LocalDateTime.ToString('MM-dd HH:mm') } else { '-' }
        $disp = if ($n.given_name) { $n.given_name } else { $n.name }
        $name = if ($ip -and $aliasByIp.ContainsKey($ip)) { $aliasByIp[$ip] } else { $disp }
        $num++
        $rows += [pscustomobject]@{ Num = $num; Name = $name; IP = $ip; Type = 'tailnet'; Online = $(if ($n.online) { '🌍online' } else { '🚫offline' }); Seen = $seen; Token = $disp; User = $null; Jump = $null; Ver = '-' }
        # 该 B 身后的 C（缩进挂其下，经此 B 两跳可达）
        if ($n.given_name) {
            $cs = @($allMachines | Where-Object { $_.type -eq 'lan' -and $_.jump -eq $n.given_name })
            foreach ($c in $cs) {
                $matchedLan[$c.name] = $true
                $num++
                $rows += [pscustomobject]@{ Num = $num; Name = ('  ' + $c.name); IP = $c.ip; Type = 'lan'; Online = '-'; Seen = '-'; Token = $c.name; User = $c.user; Jump = $c.jump; Ver = '-' }
            }
        }
    }
    # pub 直连机器与跳板不在上表的 lan 条目：平铺表尾
    $pubs = @($allMachines | Where-Object { $_.type -eq 'pub' })
    $orphans = @($allMachines | Where-Object { $_.type -eq 'lan' -and -not $matchedLan.ContainsKey($_.name) })
    foreach ($pu in $pubs) {
        $num++
        $rows += [pscustomobject]@{ Num = $num; Name = $pu.name; IP = $pu.ip; Type = 'pub'; Online = '-'; Seen = '-'; Token = $pu.name; User = $pu.user; Jump = $null }
    }
    foreach ($o in $orphans) {
        $num++
        $rows += [pscustomobject]@{ Num = $num; Name = $o.name; IP = $o.ip; Type = 'lan'; Online = '-'; Seen = '-'; Token = $o.name; User = $o.user; Jump = $o.jump }
    }
    return @{ Rows = $rows; Log = $changeLog; Failed = $false }
}

function Get-DisplayWidth([string]$s) {
    # 东亚宽度感知：CJK/全角按 2 列，其余按 1（conhost/Windows Terminal 等宽字体下与实际显示一致）
    $w = 0
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if (($code -ge 0x1100 -and $code -le 0x115F) -or ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE30 -and $code -le 0xFE4F) -or ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Format-Cell([string]$s, [int]$width) {
    # 按显示宽度左对齐填充；超宽截断（保留 2 列余量放省略号）
    if ((Get-DisplayWidth $s) -gt ($width - 2)) {
        $out = ''
        $acc = 0
        foreach ($ch in $s.ToCharArray()) {
            $cw = Get-DisplayWidth $ch
            if ($acc + $cw -gt $width - 3) { break }
            $out += $ch
            $acc += $cw
        }
        $s = $out + '…'
    }
    return ($s + (' ' * ($width - (Get-DisplayWidth $s))))
}

function Show-MachineRows($rows) {
    $wName = 34
    Write-Output ((Format-Cell '#' 4) + (Format-Cell 'NAME' $wName) + (Format-Cell 'IP' 16) + (Format-Cell 'TYPE' 9) + (Format-Cell 'ONLINE' 12) + (Format-Cell 'VER' 5) + (Format-Cell 'LAST SEEN' 14))
    foreach ($row in $rows) {
        Write-Output ((Format-Cell "$($row.Num)" 4) + (Format-Cell $row.Name $wName) + (Format-Cell $row.IP 16) + (Format-Cell $row.Type 9) + (Format-Cell "$($row.Online)" 12) + (Format-Cell "$($row.Ver)" 5) + (Format-Cell $row.Seen 14))
    }
}

function Do-Nodes {
    $r = Get-MachineRows
    # 查询失败是常态：跳过网内行，agent/pub/lan 照常展示
    if ($r.Failed) { $r.Rows = @($r.Rows) }
    foreach ($l in $r.Log) { Write-Output $l }
    Show-MachineRows $r.Rows
}

# ============ C 清单同步：遍历 agent 机器，经 via-<名> 读取 c-aliases.txt（Add-C/Rename-C 维护）============
function Do-SyncAlias([switch]$Quiet, [System.Collections.ArrayList]$changeLog) {
    # 遍历 agent 机器（V2 hub 长轮询），从 hub /info 读其上报的 C 清单；agent 机器自身别名 = 注册表名
    $machines = @(Get-Machines)
    $changed = 0
    foreach ($a in ($machines | Where-Object { $_.type -eq 'agent' })) {
        $credFile = Join-Path $pkgDir "agents\$($a.name)\hub.json"
        if (-not (Test-Path $credFile)) { continue }
        $cred = Get-Content $credFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $infoTxt = ''
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri ($cred.hub + '/info?id=' + $cred.id + '&token=' + $cred.token)
            $infoObj = $resp.Content | ConvertFrom-Json
            $infoTxt = $infoObj.caliases
        } catch { }
        $info = @{ cs = @() }
        if ($infoTxt) {
            foreach ($line in ($infoTxt -split "`r?`n")) {
                $t = $line.Trim()
                if ($t) { $info.cs += $t }
            }
        }
        foreach ($cline in $info.cs) {
            $cp = $cline -split '\|', 3
            if ($cp.Count -lt 3) { continue }
            $cip = $cp[0].Trim(); $cuser = $cp[1].Trim(); $calias = $cp[2].Trim()
            if (-not $cip -or -not $calias) { continue }
            $exC = $machines | Where-Object { $_.ip -eq $cip -and $_.type -eq 'lan' -and $_.jump -eq $a.name }
            if ($exC) {
                # 必须 ordinal 比较：-cne 是 culture 感知，U+FEFF（BOM 残留）被视为可忽略字符会误判相等
                if (-not [string]::Equals($exC.name, $calias, [System.StringComparison]::Ordinal)) {
                    $msg = ("- {0} (C of {1}): {2} -> {3}" -f $cip, $a.name, $exC.name, $calias)
                    if ($changeLog) { [void]$changeLog.Add($msg) } else { Write-Output $msg }
                    $exC.name = $calias
                    if ($cuser) { $exC.user = $cuser }
                    $changed++
                }
            } else {
                $dupC = $machines | Where-Object { $_.name -ieq $calias }
                if ($dupC) {
                    $msg = ("- {0} (C of {1}): 别名 {2} 与已有条目（{3} {4}）重名，跳过 — Rename-C 换名" -f $cip, $a.name, $calias, $dupC.type, $dupC.ip)
                    if ($changeLog) { [void]$changeLog.Add($msg) } else { Write-Output $msg }
                    continue
                }
                $msg = ("- {0} (C of {1}): 新增别名 {2}" -f $cip, $a.name, $calias)
                if ($changeLog) { [void]$changeLog.Add($msg) } else { Write-Output $msg }
                $machines += [pscustomobject]@{ name = $calias; ip = $cip; user = $cuser; type = 'lan'; jump = $a.name }
                $changed++
            }
        }
    }
    if ($changed -gt 0) {
        Set-Machines $machines
        if (-not $Quiet -and -not $changeLog) { Write-Output "已同步 $changed 条" }
    }
    elseif (-not $Quiet -and -not $changeLog) { Write-Output '无变更' }
}

# ============ web 隧道：SSH -L 本地转发（B/C 的 web 服务在 A 本机浏览器打开）============
$TunnelsFile = Join-Path $pkgDir '.tunnels.json'

function Get-Tunnels {
    if (Test-Path $TunnelsFile) {
        $raw = Get-Content $TunnelsFile -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        if ($parsed -is [array]) { return $parsed } else { return @($parsed) }
    }
    return @()
}

function Set-Tunnels($tunnels) {
    $tunnels | ConvertTo-Json -Depth 3 | Set-Content $TunnelsFile -Encoding UTF8
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

function Do-Tunnel([string]$token, [string]$rport = '80', [string]$lport = '', [string]$targetHost = '', [switch]$NoBrowse) {
    if (-not $token) {
        Write-Output 'usage: tailpet tunnel <机器名> [服务端口=80] [本地端口=自动分配] [目标IP=该机本机]   （tailpet tunnel list 查看活动隧道）'
        Write-Output '  把该机器可访问的 web 端口转发到 A 本机并打开浏览器；agent 机经 hub 中继（B 出站拨中继，零入站）'
        return
    }
    $cands = Resolve-SshTarget $token
    if (-not $cands -or $cands.Count -eq 0) { Write-Output "!! 节点未找到: $token（tailpet nodes 查看）"; return }
    $c = $cands[0]
    if ($c.Via -eq 'agent') {
        # agent 机：hub TCP 中继（B 出站拨中继，目标可为该机本机或其内网任一 IP）
        $aid = if ($c.Jump -match '^hub:(.+)$') { $Matches[1] } else { '' }
        if (-not $aid) { Write-Output '!! agent 标识缺失'; return }
        $tHost = if ($targetHost) { $targetHost } else { '127.0.0.1' }
        $target = "$tHost`:$rport"
        $viaDesc = 'hub 中继'
    } elseif ($c.Via -eq 'lan') {
        $jumpNode = Resolve-Node $c.Jump (Get-NodesJson)
        if (-not $jumpNode) { Write-Output "!! 跳板 B 未找到: $($c.Jump)"; return }
        $sshHost = (@($jumpNode.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        $u = Get-UserFor $sshHost 'administrator'
        $target = "$($c.IP):$rport"      # B 在自己网段内可达 C 的端口
        $viaDesc = "经 $($c.Jump) 跳板"
    } else {
        $sshHost = $c.IP
        $u = Get-UserFor $c.IP 'administrator'
        $target = "127.0.0.1:$rport"
        $viaDesc = '直连'
    }
    $dedupKey = if ($c.Via -eq 'agent') { 'agent|' + $aid + '|' + $tHost + '|' + $rport } else { $c.Via + '|' + $sshHost + '|' + $target }
    # 同目标去重：已有存活的同目标隧道则直接复用（显式指定本地端口时除外）
    if (-not $lport) {
        $dup = Get-Tunnels | Where-Object { $_.key -eq $dedupKey } | Select-Object -First 1
        if ($dup) {
            $alive = $false
            try { $alive = [bool](Get-Process -Id ([int]$dup.pid) -ErrorAction Stop) } catch { }
            if ($alive) {
                $scheme = if ($rport -eq '443') { 'https' } else { 'http' }
                $url = "${scheme}://127.0.0.1:$($dup.port)"
                Write-Output "同目标隧道已存在，直接复用: $url  ->  $token ($target)"
                Write-Output "  停止: tailpet tunnel-stop $($dup.port)"
                if (-not $NoBrowse) { Start-Process $url }
                return
            }
        }
    }
    if (-not $lport) { $lport = Get-FreePort }
    $existing = Get-Tunnels | Where-Object { $_.port -eq $lport }
    if ($existing) { Write-Output "!! 本地端口 $lport 已有隧道（tailpet tunnel-stop $lport 先停止）"; return }
    if ($c.Via -eq 'agent') {
        $adminToken = (Get-Content (Join-Path $pkgDir 'hub-admin.txt') -Raw).Trim()
        $bridge = Join-Path $pkgDir 'bridge.py'
        if (-not (Test-Path $bridge)) { Write-Output '!! 缺 bridge.py（从开发仓同步安装副本）'; return }
        $errLog = Join-Path $env:TEMP ('tailpet-bridge-' + $lport + '.log')
        $proc = Start-Process python -ArgumentList @($bridge, '--hub', $P.server.host, '--relay', '80', '--admin', $adminToken, '--agent', $aid, '--target', $tHost, '--rport', $rport, '--listen', ('127.0.0.1:' + $lport)) -WindowStyle Hidden -PassThru -RedirectStandardError $errLog -RedirectStandardOutput ($errLog + '.out')
        $up = $false
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            if ($proc.HasExited) { break }
            try {
                $pc = New-Object System.Net.Sockets.TcpClient
                $pc.Connect('127.0.0.1', [int]$lport)
                $pc.Close()
                $up = $true
                break
            } catch { }
        }
        if (-not $up) {
            Write-Output '!! 中继桥启动失败'
            if (Test-Path $errLog) { Get-Content $errLog | Select-Object -First 5 }
            try { Stop-Process -Id $proc.Id -Force } catch { }
            return
        }
    } else {
        $sshArgs = @('-N', '-T', '-i', $KEY, '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
                     '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3',
                     '-L', "127.0.0.1:${lport}:$target", "$u@$sshHost")
        $proc = Start-Process ssh -ArgumentList $sshArgs -WindowStyle Hidden -PassThru
        Start-Sleep 2
        if ($proc.HasExited) { Write-Output "!! 隧道启动失败（exit $($proc.ExitCode)）— 检查机器在线与端口可达"; return }
    }
    $tunnels = @(Get-Tunnels)
    $tunnels += [pscustomobject]@{ port = $lport; pid = $proc.Id; target = "$token -> $target"; via = $viaDesc; key = $dedupKey; started = (Get-Date -Format 'MM-dd HH:mm') }
    Set-Tunnels $tunnels
    $scheme = if ($rport -eq '443') { 'https' } else { 'http' }
    $url = "${scheme}://127.0.0.1:$lport"
    Write-Output "隧道已建立: $url  ->  $token ($target, $viaDesc)"
    Write-Output "  浏览器已打开（kimi-webbridge 可直接操作 127.0.0.1）"
    Write-Output "  停止: tailpet tunnel-stop $lport"
    if (-not $NoBrowse) { Start-Process $url }
}

# ============ agent 机器（hub 长轮询）============
function Invoke-OnSEnc([string]$psScript) {
    # EncodedCommand 版跨机执行：内容含引号/管道时不受多层 shell 拆解影响
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($psScript))
    return Invoke-OnS ('powershell -NoProfile -EncodedCommand ' + $enc)
}

function Do-AgentAdd([string]$name) {
    # agent add [名]：生成 agent 离线安装包（出站长轮询经 hub）
    # 机器名单以 hub 为准（agent 首次心跳自动注册），A 端不再维护注册表
    if (-not $name) {
        Write-Output '=== 新增 agent 机器 ==='
        $name = Read-Host '机器名（中文/英文均可，如 新丰社区B）'
        if (-not $name) { Write-Output cancelled; return }
    }
    if ($name -notmatch '^\S+$') { Write-Output '!! 名不能含空白（中文/英文均可）'; return }
    $hub = 'http://' + $P.server.host + ':8443'
    # 名字查重（hub /metas）：同名 = 幂等升级——复用既有 id/token，已部署的 B 不断线
    $existingMetas = Get-AgentMetas
    $aid = ''
    $token = ''
    if ($existingMetas) {
        foreach ($kv in $existingMetas.PSObject.Properties) {
            if ($kv.Value.name -ieq $name) {
                $aid = $kv.Name
                $token = $kv.Value.token
                Write-Output "同名 agent 已存在（id $aid）——复用 id/token，按当前模板重新生成升级包"
                break
            }
        }
    }
    if (-not $aid) {
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $b6 = New-Object byte[] 6; $rng.GetBytes($b6)
        $aid = 'a' + [BitConverter]::ToString($b6).Replace('-', '').ToLower()
        $b24 = New-Object byte[] 24; $rng.GetBytes($b24)
        $token = [Convert]::ToBase64String($b24).Replace('+', '-').Replace('/', '_').Replace('=', '')
    }
    # 生成安装包（仅 agent.ps1 + Add-Agent.bat）
    $outZip = Join-Path $pkgDir "out\Agent-Bootstrap-$name.zip"
    $tplFile = Join-Path $pkgDir 'bootstrap\agent-v2.ps1.template'
    $batFile = Join-Path $pkgDir 'bootstrap\Add-Agent-V2.bat'
    if (-not (Test-Path $tplFile) -or -not (Test-Path $batFile)) {
        Write-Output '!! 安装副本缺 agent-v2 模板（bootstrap\agent-v2.ps1.template / Add-Agent-V2.bat）——从开发仓重新同步'
        return
    }
    $ps1 = Get-Content $tplFile -Raw -Encoding UTF8
    $ps1 = $ps1.Replace('{{HUB_URL}}', $hub).Replace('{{AGENT_ID}}', $aid).Replace('{{TOKEN}}', $token).Replace('{{NAME}}', $name)
    $tmpDir = Join-Path $env:TEMP ('agent-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    Copy-Item $batFile (Join-Path $tmpDir 'Add-Agent.bat')
    [IO.File]::WriteAllText((Join-Path $tmpDir 'agent.ps1'), $ps1, [Text.Encoding]::UTF8)
    $sshZip = Join-Path (Join-Path (Join-Path $pkgDir 'bootstrap') 'cache') 'OpenSSH-Win64.zip'
    $hasSsh = Test-Path $sshZip
    $zipItems = @((Join-Path $tmpDir 'Add-Agent.bat'), (Join-Path $tmpDir 'agent.ps1'))
    if ($hasSsh) {
        Copy-Item $sshZip (Join-Path $tmpDir 'OpenSSH-Win64.zip')
        $zipItems += (Join-Path $tmpDir 'OpenSSH-Win64.zip')
    }
    $plinkSrc = Join-Path (Join-Path (Join-Path $pkgDir 'bootstrap') 'cache') 'plink.exe'
    $hasWsp = Test-Path $plinkSrc
    if ($hasWsp) {
        Copy-Item $plinkSrc (Join-Path $tmpDir 'plink.exe')
        $zipItems += (Join-Path $tmpDir 'plink.exe')
    }
    Compress-Archive -Path $zipItems -DestinationPath $outZip -Force
    Remove-Item $tmpDir -Recurse -Force
    Write-Output "Agent 包已生成: $outZip"
    if ($hasSsh) { Write-Output '  已内嵌离线 OpenSSH + win-sshpass（装完即有 ssh-c 公钥模式 / ssh-p 密码模式）' } else { Write-Output '  !! bootstrap\cache 离线包缺失——本包不含 OpenSSH/win-sshpass' }
    Write-Output "  拷到目标机解压，双击 Add-Agent.bat（需管理员）——上线后 tailpet agent list 显示 online"
    Write-Output "  执行命令: tailpet agent exec $name <命令>；吊销: tailpet agent rm $name"
    # SSH ProxyCommand 条目：让 ssh <名> 透明经中继连接
    $sshConfig = Join-Path $env:USERPROFILE '.ssh\config'
    $sshDir = Split-Path $sshConfig
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Force -Path $sshDir | Out-Null }
    $marker = '# tailpet-agent:' + $aid
    $existingCfg = if (Test-Path $sshConfig) { Get-Content $sshConfig -Raw } else { '' }
    if ($existingCfg -notlike "*$marker*") {
        $nl = [Environment]::NewLine
        $relayCmd = 'python "' + (Join-Path $pkgDir 'ssh-relay.py') + '" ' + $aid + ' 127.0.0.1 22'
        $block = "$marker${nl}Host $name${nl}    ProxyCommand $relayCmd${nl}    User administrator$nl"
        Add-Content -Path $sshConfig -Value $block -Encoding UTF8
        Write-Output '  SSH config 条目已写入 ~/.ssh/config（ssh 公司B 即可透明连接）'
    }
}

function Get-AgentMetas {
    # 从 hub 拉全部 agent meta（id -> {token, name, lastSeen, ip}）；失败返回 $null
    $adminFile = Join-Path $pkgDir 'hub-admin.txt'
    if (-not (Test-Path $adminFile)) { return $null }
    $adminToken = (Get-Content $adminFile -Raw).Trim()
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri ('http://' + $P.server.host + ':8443/metas?admin=' + $adminToken)
        return $resp.Content | ConvertFrom-Json
    } catch { return $null }
}

function Do-AgentExec([string]$name, [string]$cmd, [int]$TimeoutSec = 0) {
    # agent exec <名> <命令>：经 hub 下发命令并等待结果（非交互）
    if (-not $name -or -not $cmd) { Write-Output 'usage: tailpet agent exec <名> [-Timeout 秒] <命令...>'; return }
    # cmd /c + PS -File 会把包裹引号原样带进来，剥掉对称的一对
    $cmd = $cmd.Trim()
    if ($cmd.Length -ge 2 -and $cmd[0] -eq '"' -and $cmd[$cmd.Length - 1] -eq '"') { $cmd = $cmd.Substring(1, $cmd.Length - 2).Trim() }
    $internalOnly = $cmd.StartsWith('__')
    $metas = Get-AgentMetas
    if (-not $metas) { Write-Output '!! hub 不可达或无 agent'; return }
    $hit = $null
    foreach ($kv in $metas.PSObject.Properties) {
        if ($kv.Value.name -ieq $name) {
            # 同名取最近心跳的（防旧实例 ghost 抢命令）
            if (-not $hit -or ([long]$kv.Value.lastSeen) -gt ([long]$hit.seen)) { $hit = @{ id = $kv.Name; token = $kv.Value.token; seen = [long]$kv.Value.lastSeen } }
        }
    }
    if (-not $hit) { Write-Output "!! agent 不存在: $name（tailpet agent list 查看）"; return }
    $id = $hit.id
    # 清旧结果 + 下发 cmd（hub admin API）
    $adminFile = Join-Path $pkgDir 'hub-admin.txt'
    $adminToken = (Get-Content $adminFile -Raw).Trim()
    $send = $cmd
    if ($TimeoutSec -gt 0) { $send = '__timeout ' + $TimeoutSec + "`n" + $cmd }
    $payload = '{"c":' + ($send | ConvertTo-Json -Compress) + '}'
    $r1 = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri ('http://' + $P.server.host + ':8443/cmdset?admin=' + $adminToken + '&id=' + $id) -Method POST -Body $payload -ContentType 'application/json'
    $t0 = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    $budget = 130
    if ($TimeoutSec -gt 0) { $budget = $TimeoutSec + 60 }
    for ($i = 0; $i -lt ([int]($budget / 5)); $i++) {
        Start-Sleep 5
        if ($internalOnly) { Write-Output '已下发（内部指令，后台执行）'; return }
        $res = $null
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri ('http://' + $P.server.host + ':8443/result?id=' + $id + '&admin=' + $adminToken)
            $res = $resp.Content | ConvertFrom-Json
        } catch { }
        if ($res -and $res.result -and $res.result.time -and ([long]$res.result.time -ge ([long]$t0 - 15))) {
            if ($res.result.stdout) { Write-Output $res.result.stdout }
            if ($res.result.stderr) { Write-Output ('[stderr] ' + $res.result.stderr) }
            Write-Output ('[exit ' + $res.result.exit + ']')
            return
        }
    }
    $online = $false
    try {
        $m2 = Get-AgentMetas
        if ($m2) {
            foreach ($kv in $m2.PSObject.Properties) {
                if ($kv.Name -eq $id -and $kv.Value.lastSeen -and (([DateTimeOffset]::Now.ToUnixTimeSeconds()) - [long]$kv.Value.lastSeen) -lt 120) { $online = $true }
            }
        }
    } catch { }
    if ($online) {
        Write-Output '!! 超时未收到结果（agent 在线）—— 命令可能仍在执行或已被超时强制终止（默认 120s，-Timeout N 可放宽）；大输出请重定向到文件后 tailpet file get 取回'
    } else {
        Write-Output '!! 超时未收到结果（agent 离线）—— 检查该机网络与 agent 任务'
    }
}

function Do-AgentRm([string]$name) {
    # agent rm [名]：吊销（hub 删该 agent 全部状态）；无参时列出供选择
    $metas = Get-AgentMetas
    $agents = @()
    if ($metas) {
        foreach ($kv in $metas.PSObject.Properties) {
            $agents += [pscustomobject]@{ id = $kv.Name; name = $kv.Value.name; lastSeen = $kv.Value.lastSeen }
        }
    }
    if (-not $name) {
        if ($agents.Count -eq 0) { Write-Output '(无 agent 机器 — tailpet agent add 新增)'; return }
        Write-Output '=== 吊销哪个 agent ==='
        for ($i = 0; $i -lt $agents.Count; $i++) {
            Write-Output ('  [{0}] {1}  (id {2})' -f ($i + 1), $agents[$i].name, $agents[$i].id)
        }
        $sel = Read-Host '选择编号（直接回车取消）'
        if (-not $sel) { return }
        $idx = 0
        if (-not [int]::TryParse($sel, [ref]$idx) -or $idx -lt 1 -or $idx -gt $agents.Count) { Write-Output cancelled; return }
        $name = $agents[$idx - 1].name
    }
    $hit = $null
    foreach ($a in $agents) { if ($a.name -ieq $name) { $hit = $a; break } }
    if (-not $hit) { Write-Output "!! agent 不存在: $name（tailpet agent list 查看）"; return }
    $adminFile = Join-Path $pkgDir 'hub-admin.txt'
    $adminToken = (Get-Content $adminFile -Raw).Trim()
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri ('http://' + $P.server.host + ':8443/purge?admin=' + $adminToken + '&id=' + $hit.id) -Method POST -Body '{}' | Out-Null
    Write-Output "已吊销: $name（hub 状态已删除，该机 agent 将无法继续通信）"
}

function Get-AgentIdByName([string]$name) {
    $metas = Get-AgentMetas
    if ($metas) {
        foreach ($kv in $metas.PSObject.Properties) { if ($kv.Value.name -ieq $name) { return $kv.Name } }
    }
    return $null
}

function Do-FileList([string]$name) {
    if (-not $name) { Write-Output 'usage: tailpet file list <机器名>'; return }
    $id = Get-AgentIdByName $name
    if (-not $id) { Write-Output "!! agent 不存在: $name"; return }
    $adminToken = (Get-Content (Join-Path $pkgDir 'hub-admin.txt') -Raw).Trim()
    $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ('http://' + $P.server.host + ':8443/files?admin=' + $adminToken + '&id=' + $id)
    $files = $resp.Content | ConvertFrom-Json
    if (-not $files -or @($files).Count -eq 0) { Write-Output '(该机 hub 无暂存文件)'; return }
    Write-Output ('{0,-44} {1,12} {2}' -f 'NAME', 'SIZE', 'TIME')
    foreach ($f in @($files)) {
        Write-Output ('{0,-44} {1,12} {2}' -f $f.name, $f.size, ([DateTimeOffset]::FromUnixTimeSeconds([long]$f.mtime).LocalDateTime.ToString('MM-dd HH:mm')))
    }
}

function Do-FileGet([string]$name, [string]$remotePath, [string]$localPath) {
    if (-not $name -or -not $remotePath) { Write-Output 'usage: tailpet file get <机器名> <该机文件路径> [本地保存路径]'; return }
    $id = Get-AgentIdByName $name
    if (-not $id) { Write-Output "!! agent 不存在: $name"; return }
    $rname = 'f' + (Get-Date -Format 'yyyyMMddHHmmss')
    $adminToken = (Get-Content (Join-Path $pkgDir 'hub-admin.txt') -Raw).Trim()
    $tokById = ''
    $metas2 = Get-AgentMetas
    if ($metas2) { foreach ($kv in $metas2.PSObject.Properties) { if ($kv.Name -eq $id) { $tokById = $kv.Value.token } } }
    $hubBase = 'http://' + $P.server.host + ':8443'
    Write-Output '该机开始上传（worker 前台执行）...'
    Do-AgentExec $name ('powershell -NoProfile -ExecutionPolicy Bypass -File ' + (Join-Path $env:ProgramData 'tailpet\filexfer.ps1') + ' -Mode up -Hub http://' + $P.server.host + ':8443 -Aid ' + $id + ' -Token ' + $tokById + ' -Name ' + $rname + ' -Path "' + $remotePath + '" -DataDir ' + $env:ProgramData + '\tailpet')
    $filesUri = 'http://' + $P.server.host + ':8443/files?admin=' + $adminToken + '&id=' + $id
    Write-Output "等待该机上传 $rname ..."
    $found = $null
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep 5
        try {
            $files = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 20 -Uri $filesUri).Content | ConvertFrom-Json
            foreach ($f in @($files)) { if ($f.name -eq $rname) { $found = $f; break } }
        } catch { }
        if ($found) { break }
    }
    if (-not $found) { Write-Output '!! 上传超时（10 分钟）—— 该机传输可能报错：tailpet agent exec 查看其 xfer-*.txt 状态'; return }
    if (-not $localPath) { $localPath = Join-Path (Get-Location) $rname }
    $dl = Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -Uri ('http://' + $P.server.host + ':8443/file?admin=' + $adminToken + '&id=' + $id + '&name=' + $rname)
    [IO.File]::WriteAllBytes($localPath, $dl.Content)
    Write-Output ("已取回: $localPath (" + $found.size + " bytes)")
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ('http://' + $P.server.host + ':8443/filedel?admin=' + $adminToken + '&id=' + $id + '&name=' + $rname) -Method POST -Body '{}' -ContentType 'application/json' | Out-Null
}

function Do-FilePut([string]$name, [string]$localPath, [string]$remotePath) {
    if (-not $name -or -not $localPath) { Write-Output 'usage: tailpet file put <机器名> <本地文件> [该机目标路径=spool\同名]'; return }
    if (-not (Test-Path $localPath)) { Write-Output "!! 本地文件不存在: $localPath"; return }
    $id = Get-AgentIdByName $name
    if (-not $id) { Write-Output "!! agent 不存在: $name"; return }
    $rname = 'f' + (Get-Date -Format 'yyyyMMddHHmmss')
    $adminToken = (Get-Content (Join-Path $pkgDir 'hub-admin.txt') -Raw).Trim()
    $base = 'http://' + $P.server.host + ':8443'
    $bytes = [IO.File]::ReadAllBytes($localPath)
    $chunk = 262144
    $seq = 1
    for ($off = 0; $off -lt $bytes.Length; $off += $chunk) {
        $len = [Math]::Min($chunk, $bytes.Length - $off)
        $slice = New-Object byte[] $len
        [Array]::Copy($bytes, $off, $slice, 0, $len)
        $uri = $base + '/filechunk?admin=' + $adminToken + '&id=' + $id + '&name=' + $rname + '&seq=' + $seq
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -Uri $uri -Method POST -Body $slice -ContentType 'application/octet-stream' | Out-Null
        $seq = $seq + 1
    }
    # 注意顺序：不能先 filedone——filedone 会把分块组装并删除，B 的 worker 就 404 拿不到了。
    # 正确顺序：分块留着 → B 的 worker 按 seq 逐块下载 → exec 返回后 filedel 清理全部残留
    if (-not $remotePath) { $remotePath = 'C:' + [char]92 + 'ProgramData' + [char]92 + 'tailpet' + [char]92 + 'spool' + [char]92 + (Split-Path -Leaf $localPath) }
    Write-Output ("hub 已暂存 $($bytes.Length) bytes —— 下发到该机 $remotePath")
    $tokById = ''
    $metas2 = Get-AgentMetas
    if ($metas2) { foreach ($kv in $metas2.PSObject.Properties) { if ($kv.Name -eq $id) { $tokById = $kv.Value.token } } }
    Do-AgentExec $name ('powershell -NoProfile -ExecutionPolicy Bypass -File C:/ProgramData/tailpet/filexfer.ps1 -Mode dn -Hub http://' + $P.server.host + ':8443 -Aid ' + $id + ' -Token ' + $tokById + ' -Name ' + $rname + ' -Path "' + $remotePath + '" -DataDir C:/ProgramData/tailpet')
    # 清理 hub 侧分块（filedel 连带 part.*）
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri ($base + '/filedel?admin=' + $adminToken + '&id=' + $id + '&name=' + $rname) -Method POST -Body '{}' -ContentType 'application/json' | Out-Null
    } catch { }
    Write-Output '已下发（如上 exit 0 即成功）—— 验证: tailpet agent exec <名> "type <目标路径>"'
}

function Do-AgentList {
    # agent list：hub /metas 驱动（name/lastSeen → 在线状态）
    $metas = Get-AgentMetas
    if ($null -eq $metas) { Write-Output '!! hub 不可达'; return }
    $now = [DateTimeOffset]::Now.ToUnixTimeSeconds()
    Write-Output ((Format-Cell 'NAME' 26) + '  ' + (Format-Cell 'LAST SEEN' 13) + '  ' + (Format-Cell 'STATUS' 13) + (Format-Cell 'VER' 5) + 'ID')
    $any = $false
    $rows = @()
    foreach ($kv in $metas.PSObject.Properties) {
        $any = $true
        $m = $kv.Value
        $ison = [bool]($m.lastSeen -and ($now - [long]$m.lastSeen) -lt 90)
        $ls = if ($m.lastSeen) { ([DateTimeOffset]::FromUnixTimeSeconds([long]$m.lastSeen).LocalDateTime.ToString('MM-dd HH:mm')) } else { '-' }
        $rows += [pscustomobject]@{ Name = $m.name; Ls = $ls; Online = $(if ($ison) { '🌍online' } else { '🚫offline' }); Ver = $(if ($m.ver) { $m.ver } else { '-' }); Id = ('id ' + $kv.Name); Orank = $(if ($ison) { 0 } else { 1 }) }
    }
    foreach ($r in ($rows | Sort-Object -Property Orank, Name)) {
        Write-Output ((Format-Cell $r.Name 26) + '  ' + (Format-Cell $r.Ls 13) + '  ' + (Format-Cell $r.Online 13) + (Format-Cell $r.Ver 5) + $r.Id)
    }
    if (-not $any) { Write-Output '(无 agent 机器 — tailpet agent add 新增)' }
}


function Do-TunnelList {
    $tunnels = @(Get-Tunnels)
    if ($tunnels.Count -eq 0) { Write-Output '(无活动隧道 — tailpet tunnel <名> <端口> 建立)'; return }
    Write-Output ((Format-Cell '本地端口' 10) + '  ' + (Format-Cell '目标' 38) + '  ' + (Format-Cell '方式' 10) + '建立  状态')
    $aliveList = @()
    foreach ($t in $tunnels) {
        $alive = $false
        try { $alive = [bool](Get-Process -Id ([int]$t.pid) -ErrorAction Stop) } catch { }
        if ($alive) {
            $aliveList += $t
            Write-Output ((Format-Cell $t.port 10) + '  ' + (Format-Cell $t.target 38) + '  ' + (Format-Cell $t.via 10) + $t.started + '  运行中')
        } else {
            Write-Output ((Format-Cell $t.port 10) + '  ' + (Format-Cell $t.target 38) + '  ' + (Format-Cell $t.via 10) + $t.started + '  已失联（自动清理）')
        }
    }
    if ($aliveList.Count -ne $tunnels.Count) { Set-Tunnels $aliveList }  # 顺手清掉失联记录
}

function Do-TunnelStop([string]$lport) {
    $tunnels = @(Get-Tunnels)
    if ($tunnels.Count -eq 0) { Write-Output '(无活动隧道)'; return }
    $targets = if ($lport) { @($tunnels | Where-Object { $_.port -eq $lport }) } else { $tunnels }
    if ($targets.Count -eq 0) { Write-Output "!! 本地端口 $lport 无隧道记录（tailpet web-stop 不带参数停止全部）"; return }
    foreach ($t in $targets) {
        try { Stop-Process -Id $t.pid -Force -ErrorAction Stop; Write-Output "已停止: $($t.target) (port $($t.port), pid $($t.pid))" }
        catch { Write-Output "进程已不在（清理记录）: $($t.target) (port $($t.port))" }
    }
    $kept = @($tunnels | Where-Object { $targets -notcontains $_ })
    Set-Tunnels $kept
}


function Do-Status { & $TS status }

function Do-Key {
    $out = Invoke-OnS ($HS + ' preauthkeys create --user 1 --expiration 24h --reusable')
    if ($out -match '(hskey-auth-\S+)') {
        Write-Output ('fresh preauth key (24h, reusable): ' + $Matches[1])
        Write-Output 'usage: tailpet gen-b --zip 生成含新钥匙的 B 离线安装包'
    } else { Write-Output ('mint failed: ' + $out) }
}

function Resolve-NodeToken([string]$token) {
    # rename/remove 的节点解析：按名字/IP（拒绝纯数字——nodes 表 # 是行号不是节点 ID，防错删）
    # 消息必须 Write-Host：Write-Output 会混进返回值（$n 变数组，-not $n 守卫失效，曾致裸命令发出）
    if ($token -match '^\d+$') { Write-Host "!! 请用节点名操作（tailpet nodes 的 # 列是行号，不是节点 ID）"; return $null }
    $n = Resolve-Node $token (Get-NodesJson)
    if (-not $n) { Write-Host "!! 节点未找到: $token（tailpet nodes 查看）" }
    return $n
}

function Do-Rename([string]$token, [string]$name) {
    if (-not $token -or -not $name) { Write-Output 'usage: tailpet rename <节点名> <新主机名>'; return }
    if ($name -match '\s') { Write-Output '!! 名字不能含空格'; return }
    $n = Resolve-NodeToken $token
    if (-not $n) { return }
    $out = Invoke-OnS ($HS + ' nodes rename "' + $name + '" -i ' + $n.id + ' --force')
    Write-Output $out
    Do-Nodes
}

function Do-Remove([string]$token) {
    if (-not $token) { Write-Output 'usage: tailpet remove <节点名>'; return }
    $n = Resolve-NodeToken $token
    if (-not $n) { return }
    $out = Invoke-OnS ($HS + ' nodes delete -i ' + $n.id + ' --force')
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
    # 嵌套引号链（stdin 管道 / bash -c 双引号）在 PS→ssh→cmd 必拆散（曾致 DISTRO_NOT_FOUND 且静默没写入）
    # 改 base64 单命令：bash 里解码写盘 + HUP，全链无引号敏感字符
    $json = ConvertTo-Json $policyObj -Depth 6
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    Invoke-OnS ("wsl -d " + $P.server.wsl_distro + " -u root bash -c 'echo " + $b64 + " | base64 -d > /etc/headscale/acl.hujson && pkill -HUP -x headscale'") | Out-Null
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
    if (Test-Path $memoFile) {
        $memo = Get-Content $memoFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $prop = $memo.PSObject.Properties[$ip]
        if ($prop -and $prop.Value) { return $prop.Value }
    }
    return 'administrator'
}

function Save-UserFor([string]$ip, [string]$u) {
    $memoFile = Join-Path $pkgDir '.ssh_last.json'
    $memo = if (Test-Path $memoFile) { Get-Content $memoFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { New-Object PSObject }
    $memo | Add-Member -NotePropertyName $ip -NotePropertyValue $u -Force
    $memo | ConvertTo-Json | Set-Content $memoFile -Encoding UTF8
}



function Test-SshReachable([string]$ip, [int]$timeoutSec = 3) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $result = $tcp.BeginConnect($ip, 22, $null, $null)
        $wait = $result.AsyncWaitHandle.WaitOne($timeoutSec * 1000)
        if ($wait -and $tcp.Connected) { return $true }
        return $false
    } finally { $tcp.Close() }
}

function Resolve-SshTarget([string]$token) {
    # 返回候选路径列表
    $candidates = @()

    if ($token -match '^\d+\.\d+\.\d+\.\d+$') {
        # 直接给 IP：先查注册表获取存储的用户名和类型
        $regMachines = Get-Machines
        foreach ($m in $regMachines) {
            if ($m.ip -eq $token) {
                $candidates += [pscustomobject]@{ IP = $m.ip; Via = $m.type; User = $m.user; Jump = $m.jump }
                return $candidates
            }
        }
        # 注册表没匹配：按 IP 段判断类型
        if ($token -match '^100\.') {
            $candidates += [pscustomobject]@{ IP = $token; Via = 'tailnet'; User = $null }
        } else {
            $candidates += [pscustomobject]@{ IP = $token; Via = 'pub'; User = $null }
        }
        return $candidates
    }

    # 名字：查注册表（pub 优先）
    $machines = Get-Machines
    foreach ($m in $machines) {
        if ($m.name -ieq $token) {
            if ($m.type -eq 'pub') {
                $candidates += [pscustomobject]@{ IP = $m.ip; Via = 'pub'; User = $m.user }
            } elseif ($m.type -eq 'lan') {
                $candidates += [pscustomobject]@{ IP = $m.ip; Via = 'lan'; User = $m.user; Jump = $m.jump }
                return $candidates  # lan 无降级
            } elseif ($m.type -eq 'tailnet') {
                $candidates += [pscustomobject]@{ IP = $m.ip; Via = 'tailnet'; User = $m.user }
                return $candidates
            } elseif ($m.type -eq 'agent') {
                # 反向隧道机器：jump 字段存 ssh config 的 via-<名> 段（内含 ProxyJump 经 S）
                $candidates += [pscustomobject]@{ IP = $m.ip; Via = 'agent'; User = $m.user; Jump = $m.jump; ConfigHost = $m.jump }
                return $candidates
            }
            break
        }
    }

    # 名字：查 hub agent（V2 心跳自动注册，经 hub exec，不经 ssh）
    $metas = Get-AgentMetas
    if ($metas) {
        foreach ($kv in $metas.PSObject.Properties) {
            if ($kv.Value.name -ieq $token) {
                $candidates += [pscustomobject]@{ IP = $kv.Value.ip; Via = 'agent'; User = 'administrator'; Jump = ('hub:' + $kv.Name) }
                return $candidates
            }
        }
    }

    # 名字：查网内节点
    $nodes = Get-NodesJson
    $n = Resolve-Node $token $nodes
    if ($n) {
        $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        if ($ip) { $candidates += [pscustomobject]@{ IP = $ip; Via = 'tailnet'; User = $null } }
    }

    return $candidates
}

function Connect-Smart([object]$candidate, [string]$userParam) {
    # 根据候选类型连接，返回 $true 成功 / $false 失败
    if ($candidate.Via -eq 'agent') {
        # 反向隧道机器：ssh config 段（via-<名>）已封装 ProxyJump 经 S + 端口 + 钥
        if (-not $candidate.ConfigHost) { Write-Output "!! agent 配置缺失（重新 gen-agent）"; return $false }
        Write-Output ">>> 经 S 中转连接 agent（$($candidate.ConfigHost)）..."
        & ssh $candidate.ConfigHost
        return $true
    }
    if ($candidate.Via -eq 'lan') {
        $jumpNode = Resolve-Node $candidate.Jump (Get-NodesJson)
        if (-not $jumpNode) { Write-Output "!! 跳板 B 未找到: $($candidate.Jump)"; return $false }
        $jumpIp = (@($jumpNode.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        $ju = Get-UserFor $jumpIp $null
        Write-Output ">>> 经 B($($candidate.Jump)) 跳转到 $($candidate.IP) ..."
        & ssh -t -i $KEY "$ju@$jumpIp" "ssh $($candidate.User)@$($candidate.IP)"
        return $true
    }

    # .ssh_last.json 优先（用户上次选择），注册表值作默认
    $memo = Get-UserFor $candidate.IP $null
    $regDefault = if ($candidate.User) { $candidate.User } else { 'administrator' }
    $u = if ($memo -ne 'administrator') { $memo } else { $regDefault }
    if ($userParam) { $u = $userParam }
    Write-Output ">>> ssh -i <管理钥> $u@$($candidate.IP) (via $($candidate.Via))"
    & ssh -i $KEY "$u@$($candidate.IP)"
    return $true
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
        Write-Output 'usage: tailpet machine add <名> <IP> [用户] [类型 pub|lan] [跳板名]'
        Write-Output '  全部按位置顺序（非命名参数）；type: pub=公网直连, lan=同网段C类(经跳板); 跳板名仅 type=lan 时需要'
        return
    }
    if (-not $user) { $user = 'administrator' }
    if (-not $type) { $type = 'pub' }
    if ($type -eq 'lan' -and -not $jump) { Write-Output '!! type=lan 需要指定 -jump <B名>'; return }
    if ($type -eq 'tailnet') {
        $n = Resolve-Node $ip (Get-NodesJson)
        if (-not $n) { Write-Output "!! tailnet 节点未找到: $ip（tailpet nodes 查看名称/IP）"; return }
        $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        $given = if ($n.given_name) { $n.given_name } else { $n.name }
        Write-Output "(绑定节点: $given / $ip)"
    }
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
    $machines = @(Get-Machines | Sort-Object -Property Name)
    if (-not $machines -or $machines.Count -eq 0) { Write-Output '(注册表为空 — tailpet machine add 添加)'; return }
    Write-Output ((Format-Cell 'NAME' 20) + ' ' + (Format-Cell 'IP' 16) + ' ' + (Format-Cell 'USER' 14) + ' ' + (Format-Cell 'TYPE' 6) + 'JUMP')
    for ($i = 0; $i -lt $machines.Count; $i++) {
        $m = $machines[$i]
        Write-Output ((Format-Cell $m.name 20) + ' ' + (Format-Cell $m.ip 16) + ' ' + (Format-Cell $m.user 14) + ' ' + (Format-Cell $m.type 6) + $m.jump)
    }
}

# ============ gen-prompt ============
function Do-GenPrompt {
    # 构建合并列表：网内节点（实时）+ 本地注册表
    $items = @()

    # 网内节点（实时数据，与 tailpet nodes 一致）
    $myip = (& $TS ip -4 2>$null | Select-Object -First 1)
    $nodes = Get-NodesJson
    foreach ($n in $nodes) {
        $ip = (@($n.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1)
        if (-not $ip -or $ip -eq $myip) { continue }
        $disp = if ($n.given_name) { $n.given_name } else { $n.name }
        $seen = if ($n.last_seen.seconds) { [DateTimeOffset]::FromUnixTimeSeconds($n.last_seen.seconds).LocalDateTime.ToString('MM-dd HH:mm') } else { '-' }
        $status = if ($n.online) { 'online' } else { 'offline' }
        $items += [pscustomobject]@{
            Label = (Format-Cell $disp 20) + ' ' + (Format-Cell $ip 14) + ' ' + $status + '  ' + $seen + '  (节点)'
            Type = 'tailnet'; IP = $ip; Name = $disp; User = $null; Jump = $null; GivenName = $disp
        }
    }

    # 注册表机器（按名排序）
    $machines = @(Get-Machines | Sort-Object -Property Name)
    foreach ($m in $machines) {
        $typeLabel = if ($m.type -eq 'lan') { "C类,经$($m.jump)" } elseif ($m.type -eq 'tailnet') { '节点别名' } else { $m.type }
        $given = $null
        if ($m.type -eq 'tailnet') {
            $n = Resolve-Node $m.ip $nodes
            if ($n) { $given = if ($n.given_name) { $n.given_name } else { $n.name } }
        }
        $dispName = if ($m.name -ieq $m.ip) { '(未命名)' } else { $m.name }
        $items += [pscustomobject]@{
            Label = (Format-Cell $dispName 18) + ' ' + (Format-Cell $m.ip 16) + ' (' + $typeLabel + ')'
            Type = $m.type; IP = $m.ip; Name = $m.name; User = $m.user; Jump = $m.jump; GivenName = $given
        }
    }

    # hub agent 机器（V2，心跳自动注册）
    $metas = Get-AgentMetas
    if ($metas) {
        $nowTs = [DateTimeOffset]::Now.ToUnixTimeSeconds()
        $agentItems = @()
        foreach ($kv in $metas.PSObject.Properties) {
            $gm = $kv.Value
            $ison = [bool]($gm.lastSeen -and ($nowTs - [long]$gm.lastSeen) -lt 90)
            $gon = if ($ison) { '🌍online' } else { '🚫offline' }
            $agentItems += [pscustomobject]@{
                Label = (Format-Cell $gm.name 26) + '  (agent' + $(if ($gm.ver) { ' v' + $gm.ver }) + ', ' + $gon + ')'
                Type = 'agent'; IP = $gm.ip; Name = $gm.name; User = 'administrator'; Jump = ('hub:' + $kv.Name); GivenName = $null
                Orank = $(if ($ison) { 0 } else { 1 })
            }
        }
        foreach ($ai in ($agentItems | Sort-Object -Property Orank, Name)) { $items += $ai }
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

    $fromNew = $false
    if ($item.Type -eq 'new') {
        $fromNew = $true
        $item = New-MachineInteractive
        if (-not $item) { return }
        # 保存到注册表
        $machines = @(Get-Machines)
        $machines += [pscustomobject]@{ name = $item.Name; ip = $item.IP; user = $item.User; type = $item.Type; jump = $item.Jump }
        Set-Machines $machines
        Write-Output "(已保存到注册表: $($item.Name))"
    }

    # 询问用户名（新建时已在 New-MachineInteractive 里问过，跳过）
    if (-not $fromNew) {
        if (-not $item.User -or $item.User -eq '-') { $item.User = 'administrator' }
        if ($item.Type -ne 'agent') {
            $inputU = Read-Host "SSH 用户 [默认 $($item.User)]"
            if ($inputU) { $item.User = $inputU }
            # 保存用户选择，tailpet ssh 连接时自动使用
            Save-UserFor $item.IP $item.User
        }
    }

    # 生成文本（C 类附带跳板 B 的信息）
    $jumpInfo = $null
    if ($item.Type -eq 'lan') {
        $jumpNode = Resolve-Node $item.Jump (Get-NodesJson)
        $bip = $null
        if ($jumpNode) { $bip = (@($jumpNode.ip_addresses) | Where-Object { $_ -match '^100\.' } | Select-Object -First 1) }
        $bu = if ($bip) { Get-UserFor $bip 'administrator' } else { 'administrator' }
        $jumpInfo = [pscustomobject]@{ Name = $item.Jump; IP = $bip; User = $bu }
    }
    $text = Build-PromptText $item $jumpInfo

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
    # 注意：此函数返回值被赋值给变量，Write-Output 会被管道吞掉
    # 交互提示必须用 Write-Host（直接写控制台，不走管道）
    Write-Host '机器类型:'
    Write-Host '  [1] 公网直连（有公网 IP）'
    Write-Host '  [2] C 类（同网段，经 B 跳板）'
    $t = Read-Host '选择'
    if ($t -eq '1') {
        $ip = Read-Host '公网 IP'
        $name = Read-Host '名称（如 web-server）'
        $user = Read-Host 'SSH 用户 [administrator]'
        if (-not $user) { $user = 'administrator' }
        return [pscustomobject]@{ Type = 'pub'; IP = $ip; Name = $name; User = $user; Jump = $null }
    } elseif ($t -eq '2') {
        $peers = Get-Peers
        Write-Host '跳板 B 是哪台?'
        for ($i = 0; $i -lt $peers.Count; $i++) {
            Write-Host ('  [{0}] {1}' -f ($i+1), $peers[$i].Host)
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

function Build-PromptText($item, $jumpInfo) {
    $lines = @()

    if ($item.Type -eq 'lan') {
        $bip = if ($jumpInfo -and $jumpInfo.IP) { $jumpInfo.IP } else { $null }
        $bu = if ($jumpInfo) { $jumpInfo.User } else { 'administrator' }
        $lines += '> tailpet = 本机已安装的组网管理 CLI（PATH 全局可用）不是拼写错误'
        $lines += ''
        $lines += '## 架构：A → B(' + $item.Jump + ') → C(' + $item.Name + ')'
        $lines += ''
        $lines += '### B（跳板机）'
        if ($bip) {
            $lines += '- **IP**: ' + $bip
            $lines += '- **手动 SSH**: `ssh -i ' + $KEY + ' ' + $bu + '@' + $bip + '`'
        } else {
            $lines += '- **IP**: (未解析到 — `tailpet nodes` 查看 ' + $item.Jump + ')'
        }
        $lines += '- **SSH 用户**: ' + $bu
        $lines += '- **进入交互终端**: `tailpet ssh ' + $item.Jump + '`'
        $lines += '- **远程执行命令**: `tailpet ssh ' + $item.Jump + ' "命令"`'
        $lines += ''
        $lines += '### C（目标机，与 B 同内网）'
        $lines += '- **LAN IP**: ' + $item.IP + '（与 B 同内网，A 无法直连）'
        $lines += '- **SSH 用户**: ' + $item.User
        $lines += '- **进入交互终端**: `tailpet ssh ' + $item.Name + '`（自动经 B 两跳）'
        $lines += '- **远程执行命令**: `tailpet ssh ' + $item.Name + ' "命令"`'
        $lines += '- **Web 服务访问**: `tailpet tunnel ' + $item.Name + '` —— 自动分配隧道端口并在 A 本机浏览器打开 `127.0.0.1:<隧道端口>`，默认转发该 C 的 80 端口（web 服务在其它端口时：`tailpet tunnel ' + $item.Name + ' <远端端口>`，连接自动经 B 转发，无需在 C 安装任何东西）；操作页面使用 kimi-webbridge 技能；停止 `tailpet tunnel-stop <隧道端口>`'
        $lines += ''
        $lines += '### 手动两步（tailpet 不可用时）'
        if ($bip) {
            $lines += '1. `ssh -i ' + $KEY + ' ' + $bu + '@' + $bip + '`'
        } else {
            $lines += '1. `ssh -i <管理钥> ' + $bu + '@<' + $item.Jump + ' 的 IP>`'
        }
        $lines += '2. `ssh ' + $item.User + '@' + $item.IP + '`'
        $lines += ''
        $lines += '- **注意**: '
        $lines += '    - C 须经 B 中转；`tailpet ssh ' + $item.Name + '` 已自动处理两跳'
        $lines += '    - Windows + PowerShell 5.1；复杂命令建议先落盘 .ps1；中文按 GBK 解码'
        return ($lines -join "`n")
    }

    if ($item.Type -eq 'tailnet') {
        $lines += '## ' + $item.Name
        $lines += '- **IP**: ' + $item.IP
        if ($item.GivenName -and $item.GivenName -ne $item.Name) {
            $lines += '- **节点名**: ' + $item.GivenName + '（别名由 A 端注册表管理）'
        }
        $lines += '- **SSH 用户**: ' + $item.User
        $lines += '- **进入交互终端**: `tailpet ssh ' + $item.Name + '`'
        $lines += '- **远程执行命令**: `tailpet ssh ' + $item.Name + ' "命令"`'
        $lines += '- **Web 服务访问**: `tailpet tunnel ' + $item.Name + '` —— 自动分配隧道端口并在 A 本机浏览器打开 `127.0.0.1:<隧道端口>`，默认转发该机 80 端口的网页（web 服务在其它端口时：`tailpet tunnel ' + $item.Name + ' <远端端口>`）；操作页面使用 kimi-webbridge 技能；停止 `tailpet tunnel-stop <隧道端口>`'
    }
    elseif ($item.Type -eq 'pub') {
        $lines += '## ' + $item.Name
        $lines += '- **IP**: ' + $item.IP + '（公网）'
        $lines += '- **SSH 用户**: ' + $item.User
        $lines += '- **进入交互终端**: `tailpet ssh ' + $item.Name + '`'
        $lines += '- **远程执行命令**: `tailpet ssh ' + $item.Name + ' "命令"`'
        $lines += '- **Web 服务访问**: `tailpet tunnel ' + $item.Name + '` —— 自动分配隧道端口并在 A 本机浏览器打开 `127.0.0.1:<隧道端口>`，默认转发该机 80 端口的网页（web 服务在其它端口时：`tailpet tunnel ' + $item.Name + ' <远端端口>`）；操作页面使用 kimi-webbridge 技能；停止 `tailpet tunnel-stop <隧道端口>`'
    }
    elseif ($item.Type -eq 'agent') {
        $lines += $item.Name + '（agent 模式）'
        $lines += ''
        $lines += '- **连接方式**: 经 hub 中转（出站长轮询，无需开放入站端口）。'
        $lines += ''
        $lines += '- **执行命令**: `tailpet agent exec ' + $item.Name + ' <命令>` '
        $lines += '  —— 在该机 cmd 里执行，非交互，120 秒超时。'
        $lines += ''
        $lines += '- **该机内网 C 机（密码模式，推荐）**: `tailpet agent exec ' + $item.Name + ' "ssh-p 密码 用户@C_IP 命令"` —— 走 plink 密码认证（keyscan 自动信任主机密钥），C 机零预装'
        $lines += '  公钥模式（C 已装该机公钥时）: `tailpet agent exec ' + $item.Name + ' "ssh-c 用户@C_IP 命令"`（公钥在 hub /metas 的 pubkey 字段）。'
        $lines += ''
        $lines += '- **Web 服务访问**: `tailpet tunnel ' + $item.Name + ' <服务端口>` 其中：'
        $lines += '  - <服务端口>指目标机上的端口（web/RDP 等任意 TCP）；'
        $lines += '  - 本地端口缺省自动分配系统空闲端口（也可显式指定），分配结果见命令输出或 `tailpet tunnel-list`；'
        $lines += '  - 建好后自动打开浏览器，同目标重复执行自动复用；'
        $lines += '  - 默认转该机 127.0.0.1，服务只绑该机内网 IP 时：`tailpet tunnel ' + $item.Name + ' <服务端口> <本地端口> <目标IP>`；'
        $lines += '  - 查看用 `tailpet tunnel list`；停止用 `tailpet tunnel-stop [本地端口]`（无参数=全部）。'
        $lines += ''
        $lines += '- **命令规则**: 单行；引号最多一层；交互确认一律加静默参数；`!` 会被吞掉；不要 chcp 65001。'
        $lines += '  长度上限约 8K（超长内容用 file put 推脚本再执行）；`|` 管道符易被多层 shell 拆坏（grep 多模式用多个 -e）；'
        $lines += '  多条 ssh 命令不要用 && 串联（一条 exec 一条命令）；密码含特殊字符时 ssh-p 不可靠，改用 EncodedCommand。'
        $lines += '- **大输出/文件**: 大输出命令一律重定向到该机文件再取回——`tailpet agent exec ' + $item.Name + ' "bigcmd > C:\ProgramData\tailpet\spool\out.log"` 然后 `tailpet file get ' + $item.Name + ' C:\ProgramData\tailpet\spool\out.log`；推文件 `tailpet file put ' + $item.Name + ' 本地文件`；大日志先 makecab 压缩；exec 直接回传只适合小结果（<50KB）；长命令加 `-Timeout 秒`'
        $lines += ''
        $lines += '- **注意**:'
        $lines += '    - tailpet = 本机已安装的组网管理 CLI（PATH 全局可用）不是拼写错误。'
        $lines += '    - agent 模式不支持 ssh 交互登录。'
        $lines += '    - 远程 PowerShell 版本 2.0~5.1 不等：'
        $lines += '      - 先探测再写命令——`tailpet agent exec ' + $item.Name + ' powershell -Command Get-Host`（输出表里的 Version 行，如 2.0 / 5.1）；'
        $lines += '      - 探测为 2.0 时没有 ConvertFrom-Json / Invoke-RestMethod / Get-ScheduledTask；'
        $lines += '      - 中文输出按 GBK 解码，不要 chcp 65001。'
        $lines += '    - 复杂命令（多层引号/换行/特殊字符）改用 powershell -EncodedCommand <base64>（UTF-16LE 的 base64），彻底免转义；简单命令直接跑即可。'
        $lines += '    - 当需要打开该机可访问的 Web 服务页面进行操作时，应使用上述"Web 服务访问"的方式在本地浏览器打开，然后使用 /kimi-webbridge 技能操作。'
        return ($lines -join "`n")
    }
    $lines += '- **注意**: '
$lines += '    - tailpet = 本机已安装的组网管理 CLI（PATH 全局可用）不是拼写错误'
$lines += '    - 远程 PowerShell 版本 2.0~5.1 不等：先探测再写命令——`tailpet ssh ' + $item.Name + ' powershell -Command Get-Host`（输出表里的 Version 行，如 2.0 / 5.1）'
$lines += '    - 探测为 2.0 时没有 ConvertFrom-Json / Invoke-RestMethod / Get-ScheduledTask；中文输出按 GBK 解码，不要 chcp 65001'
$lines += '    - 复杂命令（多层引号/换行/特殊字符）改用 powershell -EncodedCommand <base64>（UTF-16LE 的 base64），彻底免转义；简单命令直接跑即可'
    return ($lines -join "`n")
}

function Invoke-TailpetSsh {
    # 形态1: tailpet ssh            交互选择器
    # 形态2: tailpet ssh <node>      交互登录
    # 形态3: tailpet ssh <node> <cmd...>  远程执行
    $nodeTok = if ($Rest.Count -ge 1) { "$($Rest[0])" } else { $null }
    $userParam = $null
    for ($i = 1; $i -lt $Rest.Count; $i++) {
        if ("$($Rest[$i])" -eq '-u' -and $i + 1 -lt $Rest.Count) { $userParam = "$($Rest[$i+1])" }
    }
    $cmdParts = @($Rest | Select-Object -Skip 1 | Where-Object { $_ -ne $userParam -and ("$_" -ne '-u') })

    if (-not $nodeTok) {
        # 交互选择器：与 tailpet nodes 同源同款（Get-MachineRows），排除本机
        $r = Get-MachineRows -ExcludeSelf
        foreach ($l in $r.Log) { Write-Output $l }
        # 查询失败是常态：跳过网内行，agent/pub/lan 照常展示
    if ($r.Failed) { $r.Rows = @($r.Rows) }
        if ($r.Rows.Count -eq 0) { Write-Output 'no machines found'; return }
        Show-MachineRows $r.Rows
        $sel = Read-Host '选择编号回车进入（直接回车取消）'
        if (-not $sel) { return }
        $row = $r.Rows[[int]$sel - 1]
        if ($row.Type -eq 'agent') {
            # agent 机：经 hub 下发，不经 ssh
            Write-Output "agent 机器（经 hub 下发，不经 ssh）：tailpet agent exec $($row.Name) <命令>"
            $acmd = Read-Host '要执行的命令（直接回车取消）'
            if ($acmd) { Do-AgentExec $row.Name $acmd }
            return
        }
        if ($row.Type -eq 'tailnet') {
            $u = Get-UserFor $row.IP $userParam
            $input_u = Read-Host "ssh 用户 [默认 $u]"
            if ($input_u) { $u = $input_u }
            Save-UserFor $row.IP $u
            Write-Output ">>> ssh -i <管理钥> $u@$($row.IP)"
            & ssh -i $KEY "$u@$($row.IP)"
        } else {
            $cand = [pscustomobject]@{ IP = $row.IP; Via = $row.Type; User = $row.User; Jump = $row.Jump }
            Connect-Smart $cand $userParam
        }
        return
    }

    # 按名/IP 智能降级连接
    $candidates = @(Resolve-SshTarget $nodeTok)
    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-Output "!! 节点未找到: $nodeTok（tailpet nodes / machine list 查看）"
        return
    }

    if ($candidates.Count -eq 1) {
        # 单一候选：直接连（不探测）
        $c = $candidates[0]
        if ($c.Via -eq 'agent') {
            # agent 机：经 hub 下发，不经 ssh
            if ($cmdParts.Count -eq 0) { Write-Output "agent 机器（经 hub 下发，不经 ssh）：tailpet agent exec $nodeTok <命令>"; return }
            Do-AgentExec $nodeTok ($cmdParts -join ' ')
            return
        }
        if ($cmdParts.Count -eq 0) {
            Connect-Smart $c $userParam
            return
        }
        # 远程执行
        $u = Get-UserFor $c.IP $userParam
        $cmd = ($cmdParts -join ' ')
        $isPs = $true
        if ($cmd -match '^(whoami|hostname)(&|\s|$)' -or $cmd -match '&\s' -or $cmd -match '/bin/' -or $cmd -match '\bsudo\b' -or $cmd -match '^wsl ') { $isPs = false; $isPs = $false }
        if ($isPs) {
            $wire = $cmd
        } else { $wire = $cmd }
        $out = & ssh -i $KEY -o BatchMode=yes "$u@$($c.IP)" $wire 2>&1
        $out | ForEach-Object { "$_" }
        exit $LASTEXITCODE
    }

    # 多候选：TCP 探测 → 选第一个通的
    $selected = $null
    foreach ($c in $candidates) {
        if ($c.Via -eq 'lan') { $selected = $c; break }
        Write-Output "  probing $($c.IP) ($($c.Via))..."
        if (Test-SshReachable $c.IP 3) {
            $selected = $c
            Write-Output "  reachable ✓"
            break
        } else {
            Write-Output "  unreachable ✗"
        }
    }
    if (-not $selected) {
        Write-Output "!! 所有路径均不可达:"
        foreach ($c in $candidates) { Write-Output "    $($c.IP) ($($c.Via))" }
        return
    }

    if ($cmdParts.Count -eq 0) {
        Connect-Smart $selected $userParam
        return
    }
    # 远程执行
    $u = Get-UserFor $selected.IP $userParam
    $cmd = ($cmdParts -join ' ')
    $wire = $cmd
    $out = & ssh -i $KEY -o BatchMode=yes "$u@$($selected.IP)" $wire 2>&1
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
    # CJK 宽度感知对齐：命令列统一 46 列（Format-Cell），描述尾随
    Write-Output 'tailpet v2.0 —— 自建组网管理 CLI（hub 控制面）'
    Write-Output ''
    $sections = @(
        @('日常：', @(
            @('tailpet ssh', '交互式选择机器进入'),
            @('tailpet ssh <名> [命令...]', '远程执行（agent 机自动经 hub 下发；其余走 ssh）'),
            @('tailpet nodes', '机器总表（agent 含在线状态）'),
            @('tailpet tunnel <名> [远端端口] [本地端口]', '端口隧道：远端网页在 A 本机浏览器打开'),
            @('tailpet tunnel list', '查看活动隧道（失联记录自动清理）'),
            @('tailpet web [-p 端口] [-d]', '本机管理页面（-d=后台，web-stop 停止）'),
            @('tailpet tunnel-stop [本地端口]', '停止隧道（不带参数=全部）'),
            @('tailpet sync-alias', '同步 C 类机器别名')
        )),
        @('agent：', @(
            @('tailpet agent add [名]', '新增 agent 机器（生成离线安装包）'),
            @('tailpet agent exec <名> <命令>', '经 hub 下发命令并等待结果'),
            @('tailpet agent list', 'agent 机器列表（含在线状态）'),
            @('tailpet agent rm [名]', '吊销 agent（无参数=列表选择）')
        )),
        @('机器管理：', @(
            @('tailpet gen-prompt', '交互式生成连接信息（自动复制到剪贴板）'),
            @('tailpet machine list', '查看本地机器注册表'),
            @('tailpet machine add <名> <IP> [用户] [类型 pub|lan] [跳板名]', '注册机器'),
            @('tailpet machine remove <名>', '从注册表删除')
        ))
    )
    foreach ($sec in $sections) {
        Write-Output $sec[0]
        foreach ($l in $sec[1]) {
            $pad = 46 - (Get-DisplayWidth $l[0])
            if ($pad -lt 2) { Write-Output ('  ' + $l[0] + '  ' + $l[1]) }
            else { Write-Output ('  ' + $l[0] + (' ' * $pad) + $l[1]) }
        }
        Write-Output ''
    }
}

# ============ 分发 ============
switch ($Cmd.ToLower()) {
    'ssh'      { Invoke-TailpetSsh }
    'nodes'    { Do-Nodes }
    'sync-alias' { Do-SyncAlias }
    'tunnel'     {
        if ("$($Rest[0])" -eq 'list') { Do-TunnelList }
        else {
            $nb = $Rest -contains '-NoBrowse'
            $ta = @($Rest | Where-Object { "$_" -ne '-NoBrowse' })
            Do-Tunnel "$($ta[0])" "$($ta[1])" "$($ta[2])" "$($ta[3])" -NoBrowse:$nb
        }
    }
    'tunnel-stop' { if ($Rest.Count -gt 0) { Do-TunnelStop "$($Rest[0])" } else { Do-TunnelStop } }
    'tunnel-list' { Do-TunnelList }
    'web'        {
        $bg = $Rest -contains '-d'
        $ta = @($Rest | Where-Object { "$_" -ne '-d' })
        $port = ''
        $pi = [array]::IndexOf(@($ta | ForEach-Object { "$_" }), '-p')
        if ($pi -ge 0 -and $pi + 1 -lt $ta.Count) { $port = "$($ta[$pi+1])" }
        $webpy = Join-Path $pkgDir 'web.py'
        if (-not (Test-Path $webpy)) { Write-Output '!! 缺 web.py（从开发仓同步安装副本）'; return }
        $cfg = Join-Path $pkgDir 'web.json'
        if (Test-Path $cfg) {
            try { $old = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json; if ($old.pid) { $alive = [bool](Get-Process -Id ([int]$old.pid) -ErrorAction SilentlyContinue); if ($alive) { Write-Output "!! 已有控制台实例运行 (pid $($old.pid), http://127.0.0.1:$($old.port))——tailpet web-stop 先停止"; return } } } catch { }
        }
        $pyArgs = @($webpy)
        if ($port) { $pyArgs += @('--port', $port) }
        if ($bg) { $pyArgs += '--bg' }
        if ($bg) {
            # cmd /c ... >> log：重定向在 cmd 内部——Start-Process 带重定向参数会走 UseShellExecute=false，
            # 句柄继承变化导致调用方管道被隐藏的 python 持有（曾致外层命令挂死）
            $webLog = Join-Path $env:TEMP 'tailpet-web.log'
            $cmdLine = 'python "' + $webpy + '"' + $(if ($port) { ' --port ' + $port }) + ' --bg >> "' + $webLog + '" 2>&1'
            Start-Process cmd -ArgumentList '/c', $cmdLine -WindowStyle Hidden | Out-Null
            Start-Sleep 3
            try { $wc = Get-Content (Join-Path $pkgDir 'web.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $wc = $null }
            if ($wc -and $wc.pid -and (Get-Process -Id ([int]$wc.pid) -ErrorAction SilentlyContinue)) {
                Write-Output "控制台已后台运行 (pid $($wc.pid), http://127.0.0.1:$($wc.port))——停止: tailpet web-stop"
            } else { Write-Output '!! 控制台启动失败（查看 %TEMP%	ailpet-web.log）' }
        } else {
            Write-Output '控制台前台运行中（Ctrl+C 停止）...'
            & python @pyArgs
        }
    }
    'web-stop'   {
        $cfg = Join-Path $pkgDir 'web.json'
        if (-not (Test-Path $cfg)) { Write-Output '(无后台控制台记录)'; return }
        try { $old = Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $old = $null }
        if ($old -and $old.pid) {
            try { Stop-Process -Id ([int]$old.pid) -Force -ErrorAction Stop; Write-Output "已停止 (pid $($old.pid))" } catch { Write-Output "进程已不在（pid $($old.pid)）" }
        } else { Write-Output '(web.json 无 pid——前台实例请用 Ctrl+C)' }
    }
    'file'       {
        $sub = "$($Rest[0])"
        if ($sub -eq 'list') { Do-FileList "$($Rest[1])" }
        elseif ($sub -eq 'get') { Do-FileGet "$($Rest[1])" "$($Rest[2])" "$($Rest[3])" }
        elseif ($sub -eq 'put') { Do-FilePut "$($Rest[1])" "$($Rest[2])" "$($Rest[3])" }
        else { Write-Output 'usage: tailpet file list <名> | get <名> <该机文件> [本地路径] | put <名> <本地文件> [该机目标路径]' }
    }
    'agent'      {
        $sub = "$($Rest[0])"
        if ($sub -eq 'add') { if ($Rest.Count -gt 1) { Do-AgentAdd "$($Rest[1])" } else { Do-AgentAdd } }
        elseif ($sub -eq 'rm') { Do-AgentRm "$($Rest[1])" }
        elseif ($sub -eq 'list') { Do-AgentList }
        elseif ($sub -eq 'exec') {
            if ($Rest.Count -ge 3) {
                $cmdRest = @($Rest | Select-Object -Skip 2)
                $toSec = 0
                $filtered = @()
                for ($i = 0; $i -lt $cmdRest.Count; $i++) {
                    if ("$($cmdRest[$i])" -eq '-Timeout' -and $i + 1 -lt $cmdRest.Count) { $toSec = [int]"$($cmdRest[$i+1])"; $i = $i + 1 }
                    else { $filtered += "$($cmdRest[$i])" }
                }
                Do-AgentExec "$($Rest[1])" ($filtered -join ' ') $toSec
            } else { Write-Output 'usage: tailpet agent exec <名> [-Timeout 秒] <命令...>' }
        }
        else { Write-Output 'usage: tailpet agent add [名] | rm <名> | list | exec <名> <命令...>' }
    }
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
    'help'         { Show-Help }
    default        { Show-Help }
}
