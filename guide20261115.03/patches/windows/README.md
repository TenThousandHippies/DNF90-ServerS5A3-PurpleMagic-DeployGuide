# Windows 侧补丁约定

登录器构建只需要 `runtime\launcher-input\profile.json` 与美术素材，当前**没有必须的源码补丁**；
如果以后为了某个功能要改 `launcher/Flutter` 或 `launcher/Engine`，按下面放补丁，交互脚本会自动列出。

## 必要补丁（每次拉源码后都要打）

目录：`patches\windows\required\<名称>\`

- `README.md`：第一行写用途；
- `apply.ps1`：参数是 PurpleMagic 源码目录，自己判断是否已打过（幂等）。

## 可选功能补丁（按需选择）

目录：`patches\windows\features\<名称>\`

- `README.md`：第一行写用途（脚本菜单会显示）；
- `apply.ps1`：同上。

## 示例

```powershell
# patches\windows\features\my-feature\apply.ps1
param([Parameter(Mandatory=$true)][string]$Source)
$file = Join-Path $Source "launcher\Engine\LauncherEngine.cs"
$text = Get-Content $file -Raw
if ($text -notmatch "MyFeatureMarker") {
    $text = $text.Replace('public const string VersionText = "1.0.13";',
                          'public const string VersionText = "1.0.13"; // MyFeatureMarker')
    Set-Content $file $text -Encoding UTF8 -NoNewline
    Write-Host "my-feature applied"
} else { Write-Host "my-feature already applied" }
```
