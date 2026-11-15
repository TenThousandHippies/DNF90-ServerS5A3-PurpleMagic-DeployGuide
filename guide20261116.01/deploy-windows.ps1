# DNF90 / PurpleMagic Windows 登录器构建 — 交互式脚本
# 用法：双击 deploy-windows.bat，或在 PowerShell 中执行
#   powershell -NoProfile -ExecutionPolicy Bypass -File deploy-windows.ps1
# 功能：环境检查 / 源码选择 / 必要补丁 / 可选功能补丁 / 地址校验 / 构建 / 发布

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot "windows-build.json"
$State = @{ Source = ""; Flutter = ""; DotNet = ""; Output = "dist\PurpleMagic-custom"; Mode = ""; Address = ""; PlayersHost = ""; GmHost = "" }
if (Test-Path $ConfigPath) {
    try { $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json; foreach ($k in $saved.PSObject.Properties.Name) { $State[$k] = $saved.$k } } catch {}
}

function Save-State { $State | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8 }
function Line { Write-Host ("-" * 60) }
function Ok($m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[!] $m" -ForegroundColor Yellow }
function Err($m) { Write-Host "[X] $m" -ForegroundColor Red }
function Ask($prompt, $default = "") {
    if ($default) { $v = Read-Host "$prompt [$default]" } else { $v = Read-Host $prompt }
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v.Trim()
}
function AskYes($prompt, $default = "n") {
    $v = Read-Host "$prompt [$(if ($default -eq 'y') {'Y/n'} else {'y/N'})]"
    if ([string]::IsNullOrWhiteSpace($v)) { $v = $default }
    return ($v -match '^(y|yes|Y|YES)$')
}

function Test-IPv4([string]$ip) {
    if ($ip -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { return $false }
    foreach ($p in $ip.Split('.')) { if ([int]$p -lt 0 -or [int]$p -gt 255) { return $false } }
    if ($ip -eq "0.0.0.0" -or $ip.StartsWith("127.")) { return $false }
    return $true
}
function Test-Domain([string]$d) { return ($d -match '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') }

function Find-Tool($name, $candidates) {
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Test-Env {
    Line; Write-Host "1) 构建环境检查"
    $flutter = Find-Tool "flutter" @($State.Flutter, "D:\SDKs\flutter\bin\flutter.bat", "D:\dnf-work\tools\flutter\bin\flutter.bat")
    if (-not $flutter) { Warn "未找到 Flutter，请选择 D:\...\flutter\bin\flutter.bat" } else { Ok "Flutter: $flutter" }
    $dotnet = Find-Tool "dotnet" @($State.DotNet, "D:\SDKs\dotnet8\dotnet.exe", "D:\dnf-work\tools\dotnet8\dotnet.exe")
    if (-not $dotnet) { Warn "未找到 .NET 8 SDK" } else {
        $ver = & $dotnet --version 2>$null
        if ($ver -like "8.*") { Ok ".NET SDK $ver" } else { Warn ".NET SDK $ver（需要 8.x）" }
    }
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vc = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($vc) { Ok "VS C++ 工具: $vc" } else { Warn "未找到 VS C++ 生成工具（NativeAOT 与 Flutter 构建需要）" }
    } else { Warn "未找到 vswhere（VS Build Tools 未安装？）" }
    if (Get-Command git -ErrorAction SilentlyContinue) { Ok "Git: $(git --version)" } else { Warn "Git 不在 PATH（Flutter 需要）" }
    if (Get-Command python -ErrorAction SilentlyContinue) { Ok "Python: $(python --version 2>&1)" } else { Warn "Python 不在 PATH" }
    $State.Flutter = $flutter; $State.DotNet = $dotnet; Save-State
}

function Select-Source {
    Line; Write-Host "2) 选择 PurpleMagic 源码目录"
    $def = if ($State.Source) { $State.Source } else { "D:\dnf-work\build\PurpleMagic" }
    $p = Ask "源码目录（含 launcher\、deploy\windows\、runtime\launcher-input\profile.json）" $def
    if (-not (Test-Path (Join-Path $p "deploy\windows\build_flutter_launcher.py"))) { Err "不是 PurpleMagic 源码目录：$p"; return }
    if (-not (Test-Path (Join-Path $p "runtime\launcher-input\profile.json"))) { Err "缺少 runtime\launcher-input\profile.json（从服务器复制过来）"; return }
    $State.Source = (Resolve-Path $p).Path; Save-State; Ok "源码：$($State.Source)"
}

function Apply-Required {
    Line; Write-Host "3) 必要补丁（源码升级后必须重打）"
    $dir = Join-Path $ScriptRoot "patches\windows\required"
    $any = $false
    if (Test-Path $dir) {
        Get-ChildItem $dir -Directory | ForEach-Object {
            $apply = Join-Path $_.FullName "apply.ps1"
            if (Test-Path $apply) { $any = $true; Write-Host "-> 应用 $($_.Name)"; & powershell -NoProfile -ExecutionPolicy Bypass -File $apply $State.Source }
        }
    }
    if (-not $any) { Ok "当前没有必须打的 Windows 侧补丁（profile 由服务器生成，构建无需改源码）" }
}

function Apply-Features {
    Line; Write-Host "4) 可选功能补丁"
    $dir = Join-Path $ScriptRoot "patches\windows\features"
    $any = $false
    if (Test-Path $dir) {
        Get-ChildItem $dir -Directory | ForEach-Object {
            $apply = Join-Path $_.FullName "apply.ps1"
            if (Test-Path $apply) {
                $any = $true
                $desc = ""
                $readme = Join-Path $_.FullName "README.md"
                if (Test-Path $readme) { $desc = (Get-Content $readme -TotalCount 1) }
                if (AskYes "应用功能补丁 [$($_.Name)] $desc ?" "n") {
                    & powershell -NoProfile -ExecutionPolicy Bypass -File $apply $State.Source
                    Ok "已应用 $($_.Name)"
                }
            }
        }
    }
    if (-not $any) { Ok "当前没有可选功能补丁（放到 patches\windows\features\<名称>\apply.ps1 即可）" }
}

function Set-Address {
    Line; Write-Host "5) 服务器地址与 profile 校验"
    $mode = Ask "部署方式：1=IP 直连  2=域名" $(if ($State.Mode) { $State.Mode } else { "1" })
    if ($mode -eq "2") {
        do { $base = Ask "主域名（示例 example.com，将校验 players.example.com / gm.example.com）" "" } while (-not (Test-Domain $base))
        $State.Mode = "domain"; $State.PlayersHost = "players.$base"; $State.GmHost = "gm.$base"; $State.Address = $base
        do { $ip = Ask "服务器 IP（玩家直连游戏用）" "" } while (-not (Test-IPv4 $ip))
    } else {
        do { $ip = Ask "服务器 IP（示例 192.168.200.130）" $(if ($State.Address) { $State.Address } else { "" }) } while (-not (Test-IPv4 $ip))
        $State.Mode = "ip"; $State.Address = $ip; $State.PlayersHost = $ip; $State.GmHost = $ip
    }
    if (-not $State.Source) { Warn "尚未选择源码，跳过 profile 校验"; Save-State; return }
    $profilePath = Join-Path $State.Source "runtime\launcher-input\profile.json"
    $profile = Get-Content $profilePath -Raw | ConvertFrom-Json
    $apiHost = ([Uri]$profile.ApiUrl).Host
    $gameHost = $profile.GameHost
    Write-Host "profile: ApiUrl=$($profile.ApiUrl)  GameHost=$gameHost  Port=$($profile.BootstrapPort)  Server=$($profile.ChannelServerId)"
    if ($State.Mode -eq "ip") {
        if ($apiHost -ne $ip) { Warn "profile.ApiUrl 主机是 $apiHost，与输入的 $ip 不一致：请让服务器用该 IP 重新生成 profile" }
        if ($gameHost -ne $ip) { Warn "profile.GameHost 是 $gameHost，与 $ip 不一致" }
    } else {
        if ($apiHost -ne "players.$base") { Warn "profile.ApiUrl 主机是 $apiHost，应为 players.$base" }
        if ($gameHost -ne $ip) { Warn "profile.GameHost 是 $gameHost，应为 $ip" }
    }
    Save-State; Ok "地址已记录"
}

function Invoke-Build {
    Line; Write-Host "6) 构建登录器"
    if (-not $State.Source) { Err "请先选择源码"; return }
    if (-not $State.Flutter -or -not (Test-Path $State.Flutter)) { Err "Flutter 不可用，请先跑环境检查"; return }
    if (-not $State.DotNet) { $State.DotNet = "dotnet" }
    $out = Ask "输出目录" $(if ($State.Output) { $State.Output } else { "dist\PurpleMagic-custom" })
    $State.Output = $out; Save-State
    Push-Location $State.Source
    try {
        $env:Path = (Split-Path $State.Flutter) + ";" + (Split-Path $State.DotNet) + ";" + $env:Path
        & cmd /c "build-launcher.bat `"$($State.Flutter)`" `"$($State.DotNet)`" `"$out`""
        if ($LASTEXITCODE -ne 0) { Err "构建失败（退出码 $LASTEXITCODE）"; return }
        $exe = Join-Path $State.Source ($out + ".exe")
        if (Test-Path $exe) { Ok "便携 EXE：$exe" } else { Warn "未找到 $exe" }
    } finally { Pop-Location }
}

function Publish-Bundle {
    Line; Write-Host "7) 发布自更新包到服务器（可选）"
    if (-not (AskYes "现在发布 app-update 包到 Hub？" "n")) { return }
    if (-not $State.Source) { Err "请先选择源码"; return }
    $zip = Join-Path $State.Source ($State.Output + "-app-update.zip")
    if (-not (Test-Path $zip)) { Err "找不到 $zip，请先构建"; return }
    $ver = Ask "发布版本号（必须大于当前，示例 1.0.14）" ""
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { Err "版本号格式应为 x.y.z"; return }
    $base = Ask "服务器地址（IP 或域名，用于 HTTPS）" $State.Address
    $tokenFile = Ask "管理员 Token 文件（服务器 runtime/selfhost/admin-token.txt 复制到本机）" ""
    if (-not (Test-Path $tokenFile)) { Err "Token 文件不存在"; return }
    $token = (Get-Content $tokenFile -Raw).Trim()
    $url = "https://$base/admin/api/bundle/$ver"
    Write-Host "POST $url"
    $cacert = Join-Path $ScriptRoot "local-tls.pem"
    if (-not (Test-Path $cacert)) { Warn "未找到 local-tls.pem，回退为不校验证书（-k）"; $cacert = "" }
    $args = @("-s","-X","POST",$url,"-H","Authorization: Bearer $token","--data-binary","@$zip","-w","`nhttp=%{http_code}`n")
    if ($cacert) { $args = @("-s","--cacert",$cacert,"-X","POST",$url,"-H","Authorization: Bearer $token","--data-binary","@$zip","-w","`nhttp=%{http_code}`n") } else { $args = @("-s","-k","-X","POST",$url,"-H","Authorization: Bearer $token","--data-binary","@$zip","-w","`nhttp=%{http_code}`n") }
    & curl.exe @args
}

function Show-Menu {
    while ($true) {
        Line
        Write-Host "DNF90 登录器构建（Windows）  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Line
        Write-Host "  1) 环境检查（Flutter/.NET/VS/Git/Python）"
        Write-Host "  2) 选择源码目录"
        Write-Host "  3) 打必要补丁"
        Write-Host "  4) 可选功能补丁"
        Write-Host "  5) 输入服务器地址并校验 profile"
        Write-Host "  6) 构建登录器"
        Write-Host "  7) 发布自更新包到服务器"
        Write-Host "  0) 退出"
        Line
        if ($State.Source) { Write-Host "当前：$($State.Source)" }
        if ($State.Address) { Write-Host "地址：$($State.Mode) $($State.PlayersHost)" }
        $c = Ask "请输入功能编号" "6"
        switch ($c) {
            "1" { Test-Env }
            "2" { Select-Source }
            "3" { Apply-Required }
            "4" { Apply-Features }
            "5" { Set-Address }
            "6" { Invoke-Build }
            "7" { Publish-Bundle }
            "0" { return }
            default { Err "无效编号" }
        }
        Read-Host "按回车返回菜单" | Out-Null
    }
}

Show-Menu
