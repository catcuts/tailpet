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

# ---- 1/4 复制程序 ----
Write-Output '[1/4] Copying program files...'
New-Item -ItemType Directory -Force -Path $dst, "$dst\bin", "$dst\lib", "$dst\bootstrap" | Out-Null
foreach ($f in @('tailpet.ps1', 'bridge.py', 'hub.py', 'params.example.json')) { Copy-Item "$src\$f" $dst -Force }
Copy-Item "$src\bin\tailpet.cmd" "$dst\bin\" -Force
Copy-Item "$src\lib\*" "$dst\lib\" -Force
Copy-Item "$src\bootstrap\*" "$dst\bootstrap\" -Force
New-Item -ItemType Directory -Force -Path "$dst\bootstrap\cache" | Out-Null
Copy-Item "$src\bootstrap\cache\*" "$dst\bootstrap\cache\" -Force
if (-not (Test-Path "$dst\params.json")) {
    if (Test-Path "$src\params.json") { Copy-Item "$src\params.json" $dst }
    else { Copy-Item "$src\params.example.json" "$dst\params.json"; Write-Output '      params.json created from template - EDIT IT before deploy' }
}

# ---- 2/4 PATH ----
Write-Output '[2/4] PATH (global tailpet command)...'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$dst\bin*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$dst\bin", 'User')
    Write-Output "      added $dst\bin (open a NEW terminal to use tailpet)"
} else { Write-Output '      already present' }

# ---- 3/4 依赖 ----
Write-Output '[3/4] Dependencies...'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { Write-Output '      !! python not found - install Python 3.x and re-run' } else {
    Write-Output "      python: $($py.Source)"
}

# ---- 4/4 管理密钥 ----
Write-Output '[4/4] Management keypair...'
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

Write-Output ''
Write-Output '==== tailpet installed ===='
Write-Output "  program   : $dst"
  Write-Output '  next      : open NEW terminal ->  tailpet help'
  Write-Output '  deploy    : tailpet agent add <机器名>  生成离线安装包 -> 拷到目标机双击 Add-Agent.bat'
