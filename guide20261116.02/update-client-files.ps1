param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [string]$Pvf = "",
    [string]$ClientDir = "D:\dnf-work\测试部署\游戏客户端\client",
    [string]$ServerHost = "",
    [string]$ServerUser = "ubuntu",
    [string]$RemoteDir = "/tmp/dnf-client"
)

$ErrorActionPreference = "Stop"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $Exe)) { Die "找不到 DNF.exe：$Exe" }
if ($Pvf -and -not (Test-Path $Pvf)) { Die "找不到 Script.pvf：$Pvf" }
if (-not (Test-Path (Join-Path $ClientDir "DNF.exe"))) { Die "客户端目录无效：$ClientDir" }

Write-Host "== 1/3 备份并替换本机客户端文件 =="
Copy-Item (Join-Path $ClientDir "DNF.exe") (Join-Path $ClientDir "DNF.exe.bak-$stamp") -Force
if ($Pvf) {
    Copy-Item (Join-Path $ClientDir "Script.pvf") (Join-Path $ClientDir "Script.pvf.bak-$stamp") -Force
}
Copy-Item $Exe (Join-Path $ClientDir "DNF.exe") -Force
if ($Pvf) { Copy-Item $Pvf (Join-Path $ClientDir "Script.pvf") -Force }
Ok "DNF.exe  $(Get-FileHash (Join-Path $ClientDir 'DNF.exe') -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLower() })"
if ($Pvf) { Ok "Script.pvf $(Get-FileHash (Join-Path $ClientDir 'Script.pvf') -Algorithm SHA256 | ForEach-Object { $_.Hash.ToLower() })" }

if (-not $ServerHost) {
    Write-Host ""
    Warn "未指定 -ServerHost，只替换了本机客户端；服务器 profile 仍需手动更新"
    Write-Host "下一步：重启登录器；或带 -ServerHost 重新执行以同步服务器"
    exit 0
}

Write-Host "== 2/3 上传到服务器 $ServerUser@$ServerHost =="
& ssh "${ServerUser}@${ServerHost}" "mkdir -p $RemoteDir"
if ($LASTEXITCODE -ne 0) { Die "SSH 连接失败" }
$remoteExe = "$RemoteDir/DNF.exe"
& scp $Exe "${ServerUser}@${ServerHost}:$remoteExe"
if ($LASTEXITCODE -ne 0) { Die "上传 DNF.exe 失败" }
$cmd = "bash /srv/dnf/ops/update-client-profile.sh --exe $remoteExe"
if ($Pvf) {
    $remotePvf = "$RemoteDir/Script.pvf"
    & scp $Pvf "${ServerUser}@${ServerHost}:$remotePvf"
if ($LASTEXITCODE -ne 0) { Die "上传 Script.pvf 失败" }
    $cmd += " --pvf $remotePvf"
}
Ok "上传完成"

Write-Host "== 3/3 服务器更新 profile =="
& ssh "${ServerUser}@${ServerHost}" $cmd
if ($LASTEXITCODE -ne 0) { Die "服务器更新失败；可登录服务器查看 /srv/dnf/PurpleMagic/runtime/selfhost/hub/state.json" }

Write-Host ""
Ok "全部完成"
Write-Host "客户端：完全退出登录器再打开（会拉新 bootstrap）"
Write-Host "回滚：客户端 $ClientDir\\DNF.exe.bak-$stamp；服务器 /srv/dnf/PurpleMagic/runtime/launcher-input/profile-$stamp.json"
