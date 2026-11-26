param(
    [Parameter(Mandatory = $true)][string]$ClientUpdateDir,
    [Parameter(Mandatory = $true)][string]$LauncherExe,
    [string]$OutDir = "D:\dnf-work\deliver",
    [string]$Tag = ("V217-" + (Get-Date -Format "yyyyMMdd"))
)

$ErrorActionPreference = "Stop"

function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

if (-not (Test-Path $ClientUpdateDir)) { Die "找不到客户端更新目录：$ClientUpdateDir" }
if (-not (Test-Path $LauncherExe)) { Die "找不到登录器：$LauncherExe" }

$root = Join-Path $OutDir ("DNF90-客户端更新-" + $Tag)
$client = Join-Path $root "client"
$npkDir = Join-Path $client "ImagePacks2"

if (Test-Path $root) { Remove-Item $root -Recurse -Force }
New-Item -ItemType Directory -Force $client, $npkDir | Out-Null

$files = @{
    "DNF.exe" = Join-Path $client "DNF.exe"
    "Script.pvf" = Join-Path $client "Script.pvf"
    "DpsMeter.dll" = Join-Path $client "DpsMeter.dll"
    "CombatPower.dll" = Join-Path $client "CombatPower.dll"
    "AtlasWorkers101.dll" = Join-Path $client "AtlasWorkers101.dll"
    "sprite_interface_private_features20261113.NPK" = Join-Path $npkDir "sprite_interface_private_features20261113.NPK"
}

$found = 0
foreach ($name in $files.Keys) {
    $src = Get-ChildItem $ClientUpdateDir -Recurse -File -Filter $name -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($src) {
        Copy-Item $src.FullName $files[$name] -Force
        Ok ("加入 " + $name + " (" + [math]::Round($src.Length / 1MB, 2) + " MB)")
        $found++
    } else {
        Warn ("缺少 " + $name + "，跳过")
    }
}
if ($found -eq 0) { Die "目录里没有找到任何预期文件" }

$manifest = Get-ChildItem $ClientUpdateDir -Recurse -File -Filter "manifest.json" -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($manifest) { Copy-Item $manifest.FullName (Join-Path $root "manifest.json") -Force }

Copy-Item $LauncherExe (Join-Path $root "PurpleMagic.exe") -Force
Ok "加入 PurpleMagic.exe"

$readme = @"
DNF90 客户端更新包（$Tag）

使用步骤：
1. 完全退出登录器和游戏；
2. 备份 client\DNF.exe、client\Script.pvf 及要覆盖的 DLL/NPK；
3. 把本压缩包解压到游戏根目录（与 client 文件夹同级），覆盖同名文件；
4. 没有登录器的，把 PurpleMagic.exe 放到游戏根目录；
5. 启动 PurpleMagic.exe，按提示更新。

本包包含：
  client\DNF.exe
  client\Script.pvf
  client\DpsMeter.dll
  client\CombatPower.dll
  client\AtlasWorkers101.dll
  client\ImagePacks2\sprite_interface_private_features20261113.NPK
  PurpleMagic.exe

SHA-256 见 SHA256SUMS.txt。
"@
Set-Content -Path (Join-Path $root "使用说明.txt") -Value $readme -Encoding UTF8

$sums = @()
foreach ($name in @("DNF.exe", "Script.pvf", "AtlasWorkers101.dll")) {
    if ($files.ContainsKey($name) -and (Test-Path $files[$name])) {
        $h = (Get-FileHash $files[$name] -Algorithm SHA256).Hash.ToLower()
        $sums += "$h  client\$name"
    }
}
$sums += ((Get-FileHash (Join-Path $root "PurpleMagic.exe") -Algorithm SHA256).Hash.ToLower() + "  PurpleMagic.exe")
Set-Content -Path (Join-Path $root "SHA256SUMS.txt") -Value ($sums -join "`n") -Encoding ASCII

$zip = Join-Path $OutDir ("DNF90-客户端更新-" + $Tag + ".zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $root "*") -DestinationPath $zip -CompressionLevel Optimal
Ok "打包完成：$zip"
Get-Item $zip | Select-Object FullName, Length
Write-Host ""
Write-Host "玩家解压到游戏根目录（与 client 同级）即可。"
