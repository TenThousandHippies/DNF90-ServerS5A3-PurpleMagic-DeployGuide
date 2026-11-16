# DNF90 / PurpleMagic Windows 登录器构建（交互式）
# 直接运行：deploy-windows.bat
# 主界面按回车 = 依次执行 1→8；输入编号 = 只执行该步；q = 退出

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptRoot "windows-build.json"
$State = @{ Source = ""; Flutter = ""; DotNet = ""; Output = "dist\PurpleMagic-custom"; Mode = ""; Address = ""; PlayersHost = ""; GmHost = ""; QQBinding = $true; WorkDir = "D:\dnf-work\build\pm-src"; RepoOwner = "Cec1c"; ZipDir = "D:\dnf-work\src" }
if (Test-Path $ConfigPath) {
    try {
        $saved = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        foreach ($k in $saved.PSObject.Properties.Name) { $State[$k] = $saved.$k }
    } catch {}
}

function Save-State { $State | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8 }
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
    $hint = if ($default -eq "y") { "Y/n" } else { "y/N" }
    $v = Read-Host "$prompt [$hint]"
    if ([string]::IsNullOrWhiteSpace($v)) { $v = $default }
    return ($v -match '^(y|yes|Y|YES)$')
}
function Test-IPv4([string]$ip) {
    if ($ip -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { return $false }
    foreach ($p in $ip.Split('.')) { if ([int]$p -lt 0 -or [int]$p -gt 255) { return $false } }
    return ($ip -ne "0.0.0.0" -and -not $ip.StartsWith("127."))
}
function Test-Domain([string]$d) { return ($d -match '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$') }

function Find-Tool($name, $candidates) {
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Ensure-Git {
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($dir in @("D:\dnf-work\tools\git\cmd", "C:\Program Files\Git\cmd", "$env:LOCALAPPDATA\Programs\Git\cmd")) {
        if (Test-Path (Join-Path $dir "git.exe")) {
            $env:Path = $dir + ";" + $env:Path
            return (Join-Path $dir "git.exe")
        }
    }
    return ""
}

function Test-Env {
    Line; Write-Host "1) 构建环境检查"
    $flutter = Find-Tool "flutter" @($State.Flutter, "D:\dnf-work\tools\flutter\bin\flutter.bat", "D:\SDKs\flutter\bin\flutter.bat")
    if (-not $flutter) {
        $p = Ask "未找到 Flutter，请输入 flutter.bat 路径" ""
        if ($p -and (Test-Path $p)) { $flutter = $p }
    }
    if ($flutter) { Ok "Flutter: $flutter" } else { Err "缺少 Flutter"; return $false }

    $dotnet = Find-Tool "dotnet" @($State.DotNet, "D:\dnf-work\tools\dotnet8\dotnet.exe", "D:\SDKs\dotnet8\dotnet.exe")
    if (-not $dotnet) {
        $p = Ask "未找到 .NET 8 SDK，请输入 dotnet.exe 路径" ""
        if ($p -and (Test-Path $p)) { $dotnet = $p }
    }
    if (-not $dotnet) { Err "缺少 .NET 8 SDK"; return $false }
    $ver = & $dotnet --version 2>$null
    if ($ver -like "8.*") { Ok ".NET SDK $ver" } else { Warn ".NET SDK $ver（建议 8.x）" }

    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vc = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
        if ($vc) { Ok "VS C++: $($vc -join '; ')" } else { Warn "未找到 VS C++ 生成工具" }
    } else { Warn "未找到 vswhere（VS Build Tools 未安装？）" }

    $git = Ensure-Git
    if ($git) { Ok "Git: $git" } else { Warn "未找到 git.exe；请把 D:\dnf-work\tools\git\cmd 加入 PATH" }
    if (Get-Command python -ErrorAction SilentlyContinue) { Ok "Python: $(python --version 2>&1)" } else { Warn "Python 不在 PATH" }

    $State.Flutter = $flutter; $State.DotNet = $dotnet; Save-State
    return $true
}

function Archive-OldSource {
    $old = $State.Source
    if (-not $old -or -not (Test-Path $old)) { return "" }
    if (-not (Test-Path (Join-Path $old "deploy\windows\build_flutter_launcher.py"))) { return "" }
    $root = "D:\dnf-work\build\archive"
    New-Item -ItemType Directory -Force $root | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $root ((Split-Path $old -Leaf) + "-$stamp")
    Move-Item $old $dest -Force
    Ok "旧源码已归档：$dest"
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -Skip 3 |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    return $dest
}

function Get-SourceFromZip($zipPath) {
    $work = $State.WorkDir
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory -Force $work | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $work -Force
    $inner = Get-ChildItem $work -Directory | Where-Object { Test-Path (Join-Path $_.FullName "deploy\windows\build_flutter_launcher.py") } | Select-Object -First 1
    if (-not $inner) { Err "压缩包解压后没有源码目录：$zipPath"; return "" }
    return $inner.FullName
}

function Select-Source {
    Line; Write-Host "2) 选择源码（默认从 GitHub 下载 ZIP）"
    $old = $State.Source
    Write-Host "  1) GitHub ZIP 下载（PurpleMagic main，默认）"
    Write-Host "  2) 本地 ZIP 文件"
    Write-Host "  3) 已有源码目录"
    $mode = Ask "请选择" "1"
    $src = ""
    $archived = ""
    if ($mode -eq "1") {
        Write-Host "  1) Cec1c（原作者）"
        Write-Host "  2) TenThousandHippies（fork）"
        $curOwner = if ($State.RepoOwner -eq "TenThousandHippies") { "2" } else { "1" }
        $pick = Ask "请选择源码仓库" $curOwner
        if ($pick -eq "2") { $State.RepoOwner = "TenThousandHippies" } else { $State.RepoOwner = "Cec1c" }
        Save-State
        $owner = $State.RepoOwner
        if (-not $State.ZipDir) { $State.ZipDir = "D:\dnf-work\src" }
        New-Item -ItemType Directory -Force $State.ZipDir | Out-Null
        $zip = Join-Path $State.ZipDir "PurpleMagic-main.zip"
        $part = "$zip.part"
        New-Item -ItemType Directory -Force $State.WorkDir | Out-Null
        $urls = @(
            "https://codeload.github.com/$owner/PurpleMagic/zip/refs/heads/main",
            "https://codeload.github.com/$owner/PurpleMagic/zip/refs/heads/master"
        )
        $ok = $false
        foreach ($u in $urls) {
            Write-Host "-> 下载 $u"
            & curl.exe -sS -fL --retry 3 --retry-delay 3 --connect-timeout 20 --max-time 300 -o $part $u
            if ($LASTEXITCODE -eq 0 -and (Test-Path $part)) { Move-Item $part $zip -Force; $ok = $true; break }
            Remove-Item $part -ErrorAction SilentlyContinue
        }
        if (-not $ok) { Err "下载失败（仓库 $owner）"; return $false }
        Ok "源码压缩包：$zip（$([math]::Round((Get-Item $zip).Length/1MB,1)) MB，$owner）"
        $archived = Archive-OldSource
        $src = Get-SourceFromZip $zip
    } elseif ($mode -eq "2") {
        $zip = Ask "ZIP 文件路径（PurpleMagic 源码包）" ""
        if (-not (Test-Path $zip)) { Err "文件不存在：$zip"; return $false }
        $archived = Archive-OldSource
        $src = Get-SourceFromZip $zip
    } elseif ($mode -eq "3") {
        $src = Ask "源码目录" $(if ($old) { $old } else { "D:\dnf-work\build\PurpleMagic" })
    } else {
        Err "无效选择"; return $false
    }
    if (-not $src -or -not (Test-Path (Join-Path $src "deploy\windows\build_flutter_launcher.py"))) { Err "不是 PurpleMagic 源码目录：$src"; return $false }
    $State.Source = (Resolve-Path $src).Path

    $profile = Join-Path $State.Source "runtime\launcher-input\profile.json"
    if (-not (Test-Path $profile)) {
        $candidates = @()
        if ($old) { $candidates += (Join-Path $old "runtime\launcher-input\profile.json") }
        if ($archived) { $candidates += (Join-Path $archived "runtime\launcher-input\profile.json") }
        $candidates += "D:\dnf-work\build\PurpleMagic\runtime\launcher-input\profile.json"
        $candidates += "D:\dnf-work\build\pm-1013\runtime\launcher-input\profile.json"
        $found = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        if ($found) {
            New-Item -ItemType Directory -Force (Join-Path $State.Source "runtime\launcher-input") | Out-Null
            Copy-Item $found (Join-Path $State.Source "runtime\launcher-input\profile.json") -Force
            Ok "已复制 profile.json ← $found"
            try {
                $pp0 = Get-Content (Join-Path $State.Source "runtime\launcher-input\profile.json") -Raw | ConvertFrom-Json
                Write-Host "    profile：ApiUrl=$($pp0.ApiUrl) GameHost=$($pp0.GameHost)"
            } catch {}
        } else {
            Warn "新源码缺少 runtime\launcher-input\profile.json（构建必需，来自服务器）"
            $pp = Ask "请输入本机 profile.json 的路径（留空=稍后手动放）" ""
            if ($pp -and (Test-Path $pp)) {
                New-Item -ItemType Directory -Force (Join-Path $State.Source "runtime\launcher-input") | Out-Null
                Copy-Item $pp (Join-Path $State.Source "runtime\launcher-input\profile.json") -Force
                Ok "已复制 profile.json"
                try {
                    $pp0 = Get-Content (Join-Path $State.Source "runtime\launcher-input\profile.json") -Raw | ConvertFrom-Json
                    Write-Host "    profile：ApiUrl=$($pp0.ApiUrl) GameHost=$($pp0.GameHost)"
                } catch {}
            }
        }
    }
    if (-not (Test-Path $profile)) { Err "仍缺少 profile.json，无法构建（把服务器上的 profile.json 放到 $profile）"; return $false }
    Save-State; Ok "源码：$($State.Source)"; return $true
}

function Apply-Required {
    Line; Write-Host "3) 必要补丁"
    $dir = Join-Path $ScriptRoot "patches\windows\required"
    $any = $false
    if (Test-Path $dir) {
        Get-ChildItem $dir -Directory | ForEach-Object {
            $apply = Join-Path $_.FullName "apply.ps1"
            if (Test-Path $apply) { $any = $true; Write-Host "-> 应用 $($_.Name)"; & powershell -NoProfile -ExecutionPolicy Bypass -File $apply $State.Source }
        }
    }
    if (-not $any) { Ok "当前没有必须的 Windows 侧补丁（profile 由服务器生成）" }
    return $true
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
    if (-not $any) { Ok "当前没有可选功能补丁" }
    return $true
}

function Set-Address {
    Line; Write-Host "5) 服务器地址（手动输入）"
    if (-not $State.Source) { Err "请先选择源码目录"; return $false }
    $profilePath = Join-Path $State.Source "runtime\launcher-input\profile.json"
    $profile = Get-Content $profilePath -Raw | ConvertFrom-Json

    $mode = Ask "部署方式：1=IP 直连  2=域名" $(if ($State.Mode) { (@{ip="1";domain="2"}[$State.Mode]) } else { "1" })
    if ($mode -eq "2") {
        do { $base = Ask "主域名（示例 example.com）" $(if ($State.Mode -eq "domain") { $State.Address } else { "" }) } while (-not (Test-Domain $base))
        $State.Mode = "domain"; $State.Address = $base; $State.PlayersHost = "players.$base"; $State.GmHost = "gm.$base"
        do { $ip = Ask "服务器 IP（玩家直连游戏用）" "" } while (-not (Test-IPv4 $ip))
        $expected = "players.$base"
    } else {
        $defIp = if ($State.Address) { $State.Address } else { ([Uri]$profile.ApiUrl).Host }
        do { $ip = Ask "服务器 IP（示例 192.168.200.130）" $defIp } while (-not (Test-IPv4 $ip))
        $State.Mode = "ip"; $State.Address = $ip; $State.PlayersHost = $ip; $State.GmHost = $ip
        $expected = $ip
    }
    $apiHost = ([Uri]$profile.ApiUrl).Host
    if ($apiHost -ne $expected) { Warn "profile.ApiUrl 主机是 $apiHost，与输入的 $expected 不一致：请让服务器用该地址重新生成 profile" }
    if ($profile.GameHost -ne $ip) { Warn "profile.GameHost 是 $($profile.GameHost)，与 $ip 不一致" }
    Save-State; Ok "地址已记录"; return $true
}

function Enable-QQBinding {
    Line; Write-Host "6) QQ 绑定"
    if (-not $State.Source) { Err "请先选择源码目录"; return $false }
    $profilePath = Join-Path $State.Source "runtime\launcher-input\profile.json"
    if (-not (Test-Path $profilePath)) { Err "缺少 $profilePath"; return $false }
    $d = Get-Content $profilePath -Raw | ConvertFrom-Json
    $cur = $false
    if ($d.PSObject.Properties.Name.Contains("EnableQQBinding")) { $cur = [bool]$d.EnableQQBinding }
    $enable = AskYes "是否开启 QQ 绑定功能？" $(if ($cur) { "y" } else { "n" })
    $d | Add-Member -NotePropertyName EnableQQBinding -NotePropertyValue $enable -Force
    $json = $d | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($profilePath, $json + "`n", (New-Object Text.UTF8Encoding($false)))
    $State.QQBinding = $enable; Save-State
    if ($enable) {
        Ok "已开启 QQ 绑定（EnableQQBinding=true，重新构建后生效）"
        Write-Host "    提示：绑定服务端还需要在 GM/网关配置 QQ 机器人；强制登录绑定由服务器 profile 的 RequireQQBinding 控制"
    } else {
        Ok "已关闭 QQ 绑定（EnableQQBinding=false）"
    }
    return $true
}

function Ensure-BuildInputs {
    if (-not $State.Source) { Err "请先选择源码目录"; return $false }
    $src = $State.Source
    $bl = Join-Path $src "build-launcher.bat"
    $tpl = Join-Path $ScriptRoot "build-launcher.bat"
    if (Test-Path $tpl) {
        $needCopy = $true
        if (Test-Path $bl) {
            $a = (Get-FileHash $bl -Algorithm SHA256).Hash
            $b = (Get-FileHash $tpl -Algorithm SHA256).Hash
            if ($a -eq $b) { $needCopy = $false }
        }
        if ($needCopy) { Copy-Item $tpl $bl -Force; Ok "已更新 build-launcher.bat（CRLF 版本）" }
    } elseif (-not (Test-Path $bl)) {
        Err "缺少 build-launcher.bat（工具包里也没有）"; return $false
    }
    $assets = Join-Path $src "launcher\Flutter\assets"
    $tplAssets = Join-Path $ScriptRoot "assets\launcher"
    $names = @("background.webp", "announcement.webp")
    New-Item -ItemType Directory -Force $assets | Out-Null
    Line
    Write-Host "启动器素材目录：$assets"
    Write-Host "工具包素材目录：$tplAssets"
    $missing0 = @($names | Where-Object { -not (Test-Path (Join-Path $assets $_)) })
    if ($missing0.Count -eq 0) {
        Ok "源码里已有 background.webp、announcement.webp"
    } else {
        Warn "源码里缺少：$($missing0 -join '、')"
    }
    Write-Host "可先把最新图片放进工具包 assets\launcher，再选择覆盖；直接回车则保留源码现有素材。"
    if (AskYes "是否复制工具包 assets\launcher 的图片到源码（覆盖同名文件）？" "n") {
        foreach ($n in $names) {
            $sf = Join-Path $tplAssets $n
            if (Test-Path $sf) { Copy-Item $sf (Join-Path $assets $n) -Force; Ok "已覆盖 $n" }
            else { Warn "工具包缺少 $n" }
        }
    }
    $missing = @($names | Where-Object { -not (Test-Path (Join-Path $assets $_)) })
    if ($missing.Count -gt 0) {
        Warn "仍缺少：$($missing -join '、')"
        Write-Host "请把文件放到：$assets"
        Write-Host "放好后按回车继续（直接回车 = 使用工具包自带素材）"
        Read-Host | Out-Null
        foreach ($n in $missing) {
            $dst = Join-Path $assets $n
            $sf = Join-Path $tplAssets $n
            if (-not (Test-Path $dst) -and (Test-Path $sf)) { Copy-Item $sf $dst -Force; Ok "已使用工具包素材 $n" }
        }
    }
    if (-not (Test-Path (Join-Path $assets "background.webp"))) { Err "缺少 launcher\Flutter\assets\background.webp（工具包 assets\launcher 下也没有）"; return $false }
    return $true
}

function Invoke-Build {
    Line; Write-Host "7) 构建登录器"
    if (-not $State.Source) { Err "请先选择源码目录"; return $false }
    if (-not (Ensure-BuildInputs)) { return $false }
    if (-not $State.Flutter -or -not (Test-Path $State.Flutter)) { Err "Flutter 不可用，请先执行环境检查"; return $false }
    if (-not $State.DotNet) { $State.DotNet = "dotnet" }
    $out = if ($State.Output) { $State.Output } else { "dist\PurpleMagic-custom" }
    $flutterRoot = $State.Flutter
    if (-not (Test-Path (Join-Path $flutterRoot "bin\flutter.bat"))) {
        $flutterRoot = Split-Path (Split-Path $State.Flutter)
    }
    $outPath = Join-Path $State.Source $out
    $related = @($outPath, "$outPath.zip", "$outPath-app-update.zip", "$outPath.exe", "$outPath.exe.sha256") |
        Where-Object { Test-Path $_ }
    if ($related) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $archiveDir = Join-Path $State.Source ("dist\archive\" + $stamp)
        New-Item -ItemType Directory -Force $archiveDir | Out-Null
        foreach ($f in $related) { Move-Item $f (Join-Path $archiveDir (Split-Path $f -Leaf)) -Force }
        Ok "旧输出已归档：$archiveDir"
        Get-ChildItem (Join-Path $State.Source "dist\archive") -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -Skip 3 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Push-Location $State.Source
    try {
        $env:Path = (Join-Path $flutterRoot "bin") + ";" + (Split-Path $State.DotNet) + ";" + $env:Path
        $gitExe = Ensure-Git
        if ($gitExe) { $env:Path = (Split-Path $gitExe) + ";" + $env:Path }
        & (Join-Path $State.Source "build-launcher.bat") $flutterRoot $State.DotNet $out
        if ($LASTEXITCODE -ne 0) { Err "构建失败（退出码 $LASTEXITCODE）"; return $false }
        $exe = Join-Path $State.Source ($out + ".exe")
        if (Test-Path $exe) { Ok "便携 EXE：$exe" } else { Warn "未找到 $exe" }
        return $true
    } finally { Pop-Location }
}

function Publish-Bundle {
    Line; Write-Host "8) 发布自更新包（可选）"
    if (-not $State.Source) { Err "请先选择源码目录"; return $false }
    $zip = Join-Path $State.Source ($State.Output + "-app-update.zip")
    if (-not (Test-Path $zip)) { Err "找不到 $zip，请先构建"; return $false }
    $base = if ($State.Mode -eq "domain") { "players.$($State.Address)" } elseif ($State.Address) { $State.Address } else { Ask "服务器地址（IP 或域名）" "" }
    $ver = Ask "发布版本号（必须大于当前，示例 1.0.14）" ""
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { Err "版本号格式应为 x.y.z"; return $false }
    $tokenFile = Ask "管理员 Token 文件路径（服务器 runtime/selfhost/admin-token.txt）" ""
    if (-not (Test-Path $tokenFile)) { Err "Token 文件不存在"; return $false }
    $token = (Get-Content $tokenFile -Raw).Trim()
    $url = "https://$base/admin/api/bundle/$ver"
    $cacert = Join-Path $ScriptRoot "local-tls.pem"
    if (-not (Test-Path $cacert)) { Warn "未找到 local-tls.pem，回退为不校验证书（-k）" }
    Write-Host "POST $url"
    if (Test-Path $cacert) {
        & curl.exe -s --cacert $cacert -X POST $url -H "Authorization: Bearer $token" --data-binary "@$zip" -w "`nhttp=%{http_code}`n"
    } else {
        & curl.exe -s -k -X POST $url -H "Authorization: Bearer $token" --data-binary "@$zip" -w "`nhttp=%{http_code}`n"
    }
    return $true
}

function Invoke-Sequence {
    Line; Write-Host "开始依次执行 1→8（需要输入时会就地询问）"
    if (-not (Test-Env)) { Err "步骤 1 失败，已停止"; return $false }
    if (-not (Select-Source)) { Err "步骤 2 失败，已停止"; return $false }
    if (-not (Apply-Required)) { Err "步骤 3 失败，已停止"; return $false }
    if (-not (Apply-Features)) { Err "步骤 4 失败，已停止"; return $false }
    if (-not (Set-Address)) { Err "步骤 5 失败，已停止"; return $false }
    if (-not (Enable-QQBinding)) { Err "步骤 6 失败，已停止"; return $false }
    if (-not (Invoke-Build)) { Err "步骤 7 失败，已停止"; return $false }
    if (AskYes "是否现在发布自更新包到服务器？" "n") { Publish-Bundle | Out-Null }
    Ok "全部步骤完成"
    return $true
}

function Show-Plan {
    Line
    Write-Host "DNF90 登录器构建（Windows）  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Line
    $src = if ($State.Source) { $State.Source } else { "未选择" }
    $addr = if ($State.Address) { "$($State.Mode) $($State.Address)" } else { "未设置" }
    Write-Host ("  1  环境检查        " + $(if ($State.Flutter) { "已检测" } else { "" }))
    Write-Host ("  2  选择源码        " + $src)
    Write-Host "  3  必要补丁"
    Write-Host "  4  功能补丁"
    Write-Host ("  5  地址（手动输入） " + $addr)
    Write-Host ("  6  QQ 绑定          " + $(if ($State.QQBinding) { "开启" } else { "关闭" }))
    Write-Host "  7  构建登录器"
    Write-Host "  8  发布自更新包（可选）"
    Line
}

function Show-Menu {
    while ($true) {
        Show-Plan
        Write-Host "直接按回车 = 依次执行 1→8；输入编号 = 只执行该步；q = 退出"
        $c = Ask "请输入功能编号" ""
        if ($c -eq "" -and [Console]::IsInputRedirected) { Write-Host "输入结束，退出"; return }
        switch ($c) {
            "" { Invoke-Sequence | Out-Null }
            "1" { Test-Env | Out-Null }
            "2" { Select-Source | Out-Null }
            "3" { Apply-Required | Out-Null }
            "4" { Apply-Features | Out-Null }
            "5" { Set-Address | Out-Null }
            "6" { Enable-QQBinding | Out-Null }
            "7" { Invoke-Build | Out-Null }
            "8" { Publish-Bundle | Out-Null }
            "q" { return }
            "Q" { return }
            default { Err "无效编号" }
        }
        Read-Host "按回车返回菜单" | Out-Null
    }
}

Show-Menu
