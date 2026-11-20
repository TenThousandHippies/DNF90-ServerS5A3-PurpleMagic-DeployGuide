param([switch]$All)

$ErrorActionPreference = "Stop"
$root = Join-Path $env:LOCALAPPDATA "DNF90Launcher"

function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Die($m) { Write-Host "[X] $m" -ForegroundColor Red; exit 1 }

$running = Get-Process DNF90, DNF90.Core, PurpleMagic -ErrorAction SilentlyContinue
if ($running) { Die "请先退出登录器（DNF90 / DNF90.Core / PurpleMagic 仍在运行）" }
if (-not (Test-Path $root)) { Ok "没有缓存目录：$root"; exit 0 }

function Get-Size($path) {
    if (-not (Test-Path $path)) { return 0 }
    return (Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

$before = Get-Size $root
Write-Host "缓存目录：$root"
Write-Host ("清理前：{0:N1} MB" -f ($before / 1MB))

# 1) 下载缓存（每次更新一个 zip，无限更新时会堆很多）
Remove-Item (Join-Path $root "bundle-downloads") -Recurse -Force -ErrorAction SilentlyContinue
# 2) 未完成的更新事务/旧版本残留
Get-ChildItem (Join-Path $root "portable") -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item (Join-Path $_.FullName ".updates") -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $_.FullName -Directory -Filter "failed-*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
# 3) 状态缓存（会自动重建）
Remove-Item (Join-Path $root "bootstrap.json") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root "instance.lock") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $root ".launcher-update-result.json") -Force -ErrorAction SilentlyContinue

if ($All) {
    # 连同已安装的便携缓存一起删；下次运行会从 PurpleMagic.exe 重新解压
    Get-ChildItem (Join-Path $root "portable") -Directory -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Ok "已删除 portable 缓存（下次启动会重新解压）"
}

$after = Get-Size $root
Write-Host ("清理后：{0:N1} MB" -f ($after / 1MB))
Ok ("释放约 {0:N1} MB" -f (($before - $after) / 1MB))
