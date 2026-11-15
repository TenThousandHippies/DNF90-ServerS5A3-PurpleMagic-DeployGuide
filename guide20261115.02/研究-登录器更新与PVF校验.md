# 登录器自更新 / PVF 校验 / PVF 加密 — 研究记录（2026-11-15 夜）

> 结论先行：**自更新已经实现且本次实测通过；PVF 变更可以不重编登录器，但需要执行一次"发布状态迁移"；PVF 整文件加密在现有客户端上不可行，只能做"静态加密 + 启动前解密"或水印追踪。**

---

## 1. 自更新：机制已具备，本次实测通过

### 1.1 机制

1. 网关的 Hub 在签名 bootstrap 里发布 `launcher: {version, url, size, sha256}`；
2. 登录器启动后拉取 `/launcher/v2/bootstrap.json`，验签并缓存；
3. `LauncherEngine` 判断 `bootstrap.Launcher.Version > LauncherEngine.VersionText` → `HasLauncherUpdate=true`；
4. 前端触发 `autoUpdate`：下载 → 校验大小/SHA256 → 解包校验条目 → 原子替换 `app\`（保留 `.bak` 回滚）→ 重启界面进程；
5. 结果写入 `%LocalAppData%\DNF90Launcher\portable\<payload>\.launcher-update-result.json`。

便携版也支持：便携缓存里的 `app\` 是"可被签名自更新改写"的目录，重新运行便携 EXE 不会覆盖已更新的 app。

### 1.2 实测（本次）

| 步骤 | 结果 |
| --- | --- |
| 把 `LauncherEngine.VersionText` 改成 1.0.13、pubspec 改 1.0.13，重新构建 | `PurpleMagic-1.0.13-app-update.zip`（18.7 MB） |
| `POST /admin/api/bundle/1.0.13`（Bearer admin token） | 200，返回 version/url/sha256 |
| bootstrap | `sequence` 3→4，`launcher` 字段出现 1.0.13 |
| 运行旧的 1.0.12 便携 EXE | 自动下载并安装，`.launcher-update-result.json` = `{"version":"1.0.13","succeeded":true,"stage":"healthy"}` |
| 读更新后 Core 的 `initialize` | `launcherVersion=1.0.13` |

> 版本号目前有三处：`launcher/Engine/LauncherEngine.cs` 的 `VersionText`、`launcher/Host/Launcher.Host.csproj` 的 `<Version>`、`launcher/Flutter/pubspec.yaml` 的 `version`。本次只改了第一和第三处，EXE 文件属性仍显示 1.0.12；**下次发布请三处一起改**。

### 1.3 给 PurpleMagic 加功能的流程

1. UI 改 `launcher/Flutter/lib/*.dart`；逻辑改 `launcher/Engine`/`launcher/Core`；
2. 三处版本号 +1（见上）；
3. `build-launcher.bat <flutter> <dotnet> <输出目录>`；
4. 发布 app 更新包：

```sh
TOKEN=$(cat /srv/dnf/PurpleMagic/runtime/selfhost/admin-token.txt)
CA=/srv/dnf/PurpleMagic/runtime/selfhost/tls-player/ca.pem
curl -s --cacert $CA -X POST https://192.168.200.130/admin/api/bundle/1.0.14 \
  -H "Authorization: Bearer $TOKEN" \
  --data-binary @PurpleMagic-1.0.14-app-update.zip
```

5. 玩家下次启动自动更新；不想等的玩家可直接换新的便携 EXE。
6. 约束：版本必须严格递增；更新包必须含 `dnf90.exe`、`dnf90.core.exe`、`flutter_windows.dll`、`data/app.so`、`data/icu*`；构建风味（standard/anticheat）必须一致。

---

## 2. PVF 校验：可以不重编登录器

### 2.1 关键代码

```csharp
// launcher/Engine/LauncherEngine.cs
private PlayerProfile Profile => bootstrap?.Profile ?? root;
```

- `root` = 编译进 EXE 的 profile（根信任，只用来验证签名）；
- `bootstrap` = 网关发布的**签名** bootstrap，带 `sequence` 与完整 profile；
- 登录器运行期校验 PVF/EXE 用的是 `Profile`，即 **Hub 发布的 profile**。

所以 PVF 的 `PvfSha256` 可以服务端更新，玩家不用换登录器。

### 2.2 但 GM 后台不能直接改

Hub 的连接配置页（`PUT /admin/api/connection`）**只允许改 `GameHost` 和 `BootstrapPort`**；注释写明 "Trust roots, asset hashes, channel identity ... retain their values" —— `PvfSha256`/`ExeSha256`/证书指纹被刻意冻结。

换 PVF 属于"受控迁移"：gateway 启动时若发现 `private/player-profile.json` 的 `PvfSha256/ExeSha256` 与 `hub/state.json` 里已发布的不一致，会直接拒绝启动（`approved profile changed: migrate publication state explicitly`）。

### 2.3 迁移工具（本次新增）

`/srv/dnf/tools/hub-migrate-profile.py`：

```sh
# 1) 停网关
cd /srv/dnf/PurpleMagic
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml stop gateway

# 2) 迁移到新 profile（会备份 state.json、同步 private/player-profile.json、sequence+1、清空 content）
python3 /srv/dnf/tools/hub-migrate-profile.py \
  --selfhost runtime/selfhost \
  --profile runtime/launcher-input/profile.json

# 3) 起网关
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml up -d gateway
```

实测：把 `PvfSha256` 换成一个假值后迁移，bootstrap `sequence` 1→2、`profile.PvfSha256` 变为新值、网关正常启动；再迁回真值 `sequence` 3、`ops-verify.sh` 11/11。

### 2.4 完整 PVF 更新流程（不重编登录器）

1. 服务端换 PVF：备份 → 覆盖 `/srv/dnf/assets/Script.pvf` → 移走 `runtime/docker/data/Script.pvf` → `manage.sh prepare`（仍传外部频道表）→ `manage.sh up`；
2. PurpleMagic 换 PVF：覆盖 `runtime/client-input/Script.pvf` → 重新生成 `profile.json`（新 `PvfSha256`）；
3. 迁移发布状态：停 gateway → 跑 `hub-migrate-profile.py` → 起 gateway；
4. 重建索引（`index-pvf/items/quests/professions`）并重启 gm（新 PVF 的 `pvfSha256` 也已由 `prepare.py` 写入 `gateway.json/service.json/indexer.json`）；
5. 客户端换 `Script.pvf`（手动或后续接 Hub 资源发布）；
6. **登录器不用重编**；玩家下次启动会拿到新 profile 并校验新 PVF。

> 如果连客户端文件也想自动分发，需要接 Hub 的"公告与下载源"（签名清单 + `/blobs/{sha}`）；那是另一套发布流程，本次未做。

---

## 3. PVF 加密：现有客户端下不可行

### 3.1 事实

- `Script.pvf` 头部本身就是混淆格式：`magicSignature = 0x69706B6E`、`XOR 0x55` + LCG（`gateway/internal/platform/pvf/crypto.go`），**客户端 EXE 内置同一套解密逻辑**；
- 整文件再加密后，客户端无法解析 → 登录/进图直接失败；
- 登录器当前校验的是**明文 PVF 的 SHA256**（`GameContract.VerifyClient`），不是容器哈希。

### 3.2 可选方案

| 方案 | 做法 | 代价 | 结论 |
| --- | --- | --- | --- |
| A. 登录器侧加密容器 | 分发 `.enc`，登录器验容器哈希 → 启动前解密成 `Script.pvf` | 明文仍会落盘（运行期可被提取）；要改登录器与更新链 | 只能防"直接拷文件"，收益有限 |
| B. 水印 + 签名分发 | 每个玩家/批次重打包 PVF，嵌入不可见水印；泄露可溯源 | 需要 PVF 重打包工具与分发流程 | **推荐**，兼容客户端 |
| C. 改客户端 EXE | 让 DNF.exe 支持解密容器 | 破坏 EXE 校验/更新链，风险高 | 不建议 |

### 3.3 结论

- 现有客户端**不能**读加密后的 PVF；
- 想让登录器校验"加密后的 PVF 哈希"，必须新增"容器格式 + 解密 + 哈希字段"功能（方案 A），且防不住运行期提取；
- 更实际的是方案 B：不加密内容，靠签名分发 + 水印追踪泄露源。

---

## 4. 本次遗留

1. `Launcher.Host.csproj` 的 `<Version>` 仍是 1.0.12（文件属性不匹配），下次发布三处一起改；
2. 内容自动分发（Hub 资源发布）未接，PVF 目前仍需手动替换客户端文件；
3. 方案 A/B 均未实现，本次只做了可行性分析。
