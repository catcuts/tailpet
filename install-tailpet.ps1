# install-tailpet.ps1 - tailpet 安装器（在仓库根目录，管理员 PowerShell 运行）
# 职责：复制程序到 %LOCALAPPDATA%\tailpet → PATH 全局命令 → 依赖检查 → 管理密钥
#       → A 端 sshd（离线 zip，默认装）→ 缓存拉取 → 生成 S 离线引导包
# 用法: powershell -ExecutionPolicy Bypass -File install-tailpet.ps1 [-NoSshd]
param([switch]$NoSshd)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = "$env:LOCALAPPDATA\tailpet"

Write-Output "== tailpet installer =="

# ---- 1/7 复制程序 ----
Write-Output '[1/7] Copying program files...'
New-Item -ItemType Directory -Force -Path $dst, "$dst\bin", "$dst\lib", "$dst\bootstrap" | Out-Null
foreach ($f in @('tailpet.ps1', 'deploy.py', 'params.example.json')) { Copy-Item "$src\$f" $dst -Force }
Copy-Item "$src\bin\tailpet.cmd" "$dst\bin\" -Force
Copy-Item "$src\lib\*" "$dst\lib\" -Force
Copy-Item "$src\bootstrap\*" "$dst\bootstrap\" -Force
if (-not (Test-Path "$dst\params.json")) {
    if (Test-Path "$src\params.json") { Copy-Item "$src\params.json" $dst }
    else { Copy-Item "$src\params.example.json" "$dst\params.json"; Write-Output '      params.json created from template - EDIT IT before deploy' }
}

# ---- 2/7 PATH ----
Write-Output '[2/7] PATH (global tailpet command)...'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$dst\bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$dst\bin", 'User')
    Write-Output "      added $dst\bin (open a NEW terminal to use tailpet)"
} else { Write-Output '      already present' }

# ---- 3/7 依赖 ----
Write-Output '[3/7] Dependencies...'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Write-Output '      !! python not found - install Python 3.x and re-run' } else {
    Write-Output "      python: $($py.Source)"
    $par = & python -c "import paramiko; print(paramiko.__version__)" 2>$null
    if (-not $par) {
        Write-Output '      installing paramiko...'
        & python -m pip install --user paramiko 2>&1 | Select-Object -Last 1
    } else { Write-Output "      paramiko: $par" }
}
if (-not (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
    Write-Output '      ! Tailscale client missing - will be offered from cache in step 5 (or install manually)'
} else { Write-Output '      tailscale: ok' }

# ---- 4/7 管理密钥 ----
Write-Output '[4/7] Management keypair...'
$key = "$env:USERPROFILE\.ssh\id_ed25519_tailpet"
if (-not (Test-Path $key)) {
    if (Test-Path "$env:USERPROFILE\.ssh\id_ed25519_voerka") {
        Write-Output '      legacy key id_ed25519_voerka found - reusing it (params.json keeps pointing to it)'
        $key = "$env:USERPROFILE\.ssh\id_ed25519_voerka"
    } else {
        & ssh-keygen -t ed25519 -f $key -N '""' -C 'tailpet-admin' 2>&1 | Out-Null
        Write-Output "      generated: $key"
    }
} else { Write-Output "      exists: $key" }

# ---- 5/7 缓存拉取（A 是唯一可能走代理/镜像的机器）----
Write-Output '[5/7] Downloading cache (proxy if needed)...'
Push-Location $dst
& python deploy.py fetch
Pop-Location
$msi = Get-ChildItem "$dst\cache" -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($msi -and -not (Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")) {
    $ans = Read-Host '      install Tailscale client now from cache? [y/N]'
    if ($ans -eq 'y') { Start-Process msiexec.exe -ArgumentList "/i `"$($msi.FullName)`" /qn /norestart" -Wait }
}

# ---- 6/7 A 端 sshd（离线 zip，默认装；装过自动跳过）----
if (-not $NoSshd) {
    Write-Output '[6/7] A-side sshd (offline zip)...'
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        Write-Output '      sshd already installed - skip'
    } else {
        $opt = "$dst\opt\OpenSSH-Win64"
        if (-not (Test-Path "$opt\install-sshd.ps1")) {
            Expand-Archive "$dst\cache\OpenSSH-Win64.zip" "$dst\opt" -Force
        }
        & "$opt\install-sshd.ps1" | Out-Null
        Set-Service sshd -StartupType Automatic
        Start-Service sshd
        Get-NetFirewallRule -DisplayName 'OpenSSH*' -ErrorAction SilentlyContinue |
          Where-Object { $_.Direction -eq 'Inbound' } | Set-NetFirewallRule -RemoteAddress 100.64.0.0/10
        Write-Output ('      sshd: ' + (Get-Service sshd).Status + ' (firewall scoped to tailnet)')
    }
} else { Write-Output '[6/7] A-side sshd skipped (-NoSshd)' }

# ---- 7/7 S 离线引导包 ----
Write-Output '[7/7] Generating S-Bootstrap.zip...'
Push-Location $dst
& python deploy.py make-s-zip
Pop-Location

Write-Output ''
Write-Output '==== tailpet installed ===='
Write-Output "  program   : $dst"
Write-Output "  S package : $dst\out\S-Bootstrap.zip  (copy to S, unzip, double-click START-S.bat)"
Write-Output '  next      : open NEW terminal ->  tailpet help'
