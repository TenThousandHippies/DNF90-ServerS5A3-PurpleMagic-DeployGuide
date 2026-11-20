# DNF90（ServerS5A3 + PurpleMagic）部署指南

> 适用版本：ServerS5A3 `master`（2026-11-17 更新：必须合并 `docker-instance.recommended.json`；本文旧验证点 `44e3482`）、PurpleMagic `main`（验证于 `216d5888`，Windows 构建脚本未变）。
> 本文所有路径、命令都在 192.168.200.130 这台 Ubuntu 24.04 虚拟机上实际执行过；换机器时只需替换 IP。
> **默认部署模式：无域名（纯 IP）**——`ApiUrl=https://<IP>:8443`、GM `https://<IP>`，证书带 IP SAN，玩家不需要改 hosts。需要域名时见 7.6。

## 交付物清单

| 文件 | 用途 |
| --- | --- |
| `DEPLOY_GUIDE.md` | 本指南 |
| `90cn一键部署.sh` | 上传检查 + 建目录 + 解压工具包 + 进入交互部署 |
| `update-client-profile.sh` | 服务端：客户端 EXE/PVF 变更后更新 profile、迁移 Hub 并校验 |
| `update-client-files.ps1` | Windows：替换本机客户端文件并可选上传服务器执行更新 |
| `clean-launcher-cache.ps1` | Windows：清理登录器下载/更新缓存 |
| `deploy-oneclick.sh` | Linux 侧一键部署（服务端 + 网关 + GM + 配置 + 索引 + 自检） |
| `build-launcher.bat` | Windows 侧构建脚本（Flutter + NativeAOT + 便携 EXE） |
| `deploy-windows.bat` / `.ps1` | Windows 侧交互菜单（环境/源码/补丁/地址/构建/发布） |
| `patches/windows/` | Windows 侧必要补丁与功能补丁目录约定 |
| `tools/hub-migrate-profile.py` | PVF 变更时迁移 Hub 发布状态（免重编登录器） |
| `ops-start.sh` / `ops-stop.sh` / `ops-status.sh` / `ops-logs.sh` / `ops-backup.sh` / `ops-verify.sh` | 日常运维与自检 |

---

## 0. 先看清全貌

| 组件 | 作用 | 目录 |
| --- | --- | --- |
| ServerS5A3 | Go 写的游戏服务端 + 账号 API + 管理 API | `/srv/dnf/ServerS5A3` |
| MariaDB 11.8 | 账号、角色、存档（Docker 卷） | 卷 `servers5a3-local_database` |
| PurpleMagic gateway | 玩家 HTTPS 网关（注册/登录/状态/更新清单） | `/srv/dnf/PurpleMagic` |
| PurpleMagic gm / edge | GM 网页与 nginx | 同上 |
| Windows 登录器 | 玩家注册、登录、选频道、拉起 DNF.exe | 交付目录 `PurpleMagic.exe` |

端口分工（这是最容易配错的地方）：

| 端口 | 谁访问 | 绑定 |
| --- | --- | --- |
| `7001/tcp` | 玩家客户端首个连接（频道引导） | 服务器 LAN/公网 IP |
| `10006-10508/tcp`（120 个） | 游戏频道 | 服务器 LAN/公网 IP |
| `30000-30063/udp` | 组队中继 | 服务器 LAN/公网 IP |
| `17002/tcp` | 账号 API（只给网关） | `127.0.0.1` |
| `18111/tcp` | 服务端私有管理 HTTP | `127.0.0.1` |
| `8443/tcp` | 玩家 HTTPS 网关 | `0.0.0.0` |
| `443/tcp` | GM 网页 | `0.0.0.0` |
| `18444/18080/18081` | gateway 管理 / GM / PVF 目录 | `127.0.0.1` |

---

## 1. 系统与基础环境

### 1.1 安装 Ubuntu 24.04（VMware 或物理机）

两种装法都行，本文的验证机用的是 B（cloud 镜像 + cloud-init），装完即带固定 IP 与 SSH。

**A. 用 ISO 手动安装（有控制台时最简单）**

1. VMware 新建虚拟机：4 vCPU、8 GB、40 GB，网络选 NAT（VMnet8）或桥接；加载 `ubuntu-24.04.*-live-server-amd64.iso`。
2. 安装时：语言 English、键盘默认、磁盘整盘、**勾选 Install OpenSSH server**、用户名 `ubuntu` 并设置密码。
3. 装完进系统，改静态 IP（netplan）：

```sh
sudo tee /etc/netplan/01-static.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.200.130/24]
      routes:
        - to: default
          via: 192.168.200.2
      nameservers:
        addresses: [192.168.200.2, 223.5.5.5]
EOF
sudo chmod 600 /etc/netplan/01-static.yaml
sudo netplan apply
```

网卡名用 `ip -br link` 查（VMware 常见 `ens33`/`ens160`/`enp0s17`）。

**B. 用 cloud 镜像 + cloud-init（无人值守，本文验证方式）**

1. 取 `ubuntu-24.04-server-cloudimg-amd64.vmdk`，用 `vmware-vdiskmanager` 转成可写磁盘并扩容：

```bat
vmware-vdiskmanager.exe -r ubuntu-24.04-cloudimg.vmdk -t 0 disk.vmdk
vmware-vdiskmanager.exe -x 40GB disk.vmdk
```

2. 写 cloud-init 的 `user-data` / `meta-data`，用 `mkisofs -V CIDATA` 打成 seed.iso：

```yaml
#cloud-config
hostname: dnf-s5a3
users:
  - name: ubuntu
    groups: [sudo, adm]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...你的公钥
chpasswd:
  expire: false
  users:
    - name: ubuntu
      password: dnf123456
      type: text
ssh_pwauth: true
network:
  version: 2
  ethernets:
    lan:
      match: { name: "en*" }
      dhcp4: false
      addresses: [192.168.200.130/24]
      routes:
        - to: default
          via: 192.168.200.2
      nameservers:
        addresses: [192.168.200.2, 223.5.5.5]
growpart: { mode: auto, devices: ['/'] }
resize_rootfs: true
```

```sh
mkisofs -J -R -V CIDATA -o seed.iso user-data meta-data
```

3. 虚拟机挂 `disk.vmdk` + `seed.iso`（CD-ROM）启动，1-2 分钟后 `ssh ubuntu@192.168.200.130` 即可。
4. 注意：`manage_etc_hosts` 保持默认即可；**如果设成 true，cloud-init 每次开机都会重写 `/etc/hosts`**，后加的域名解析要写进 `/etc/cloud/templates/hosts.debian.tmpl`（见 4.7 节）。

装好后自检：

```sh
hostname; ip -4 addr show | grep inet
timedatectl set-timezone Asia/Shanghai
sudo sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources
sudo apt-get update
```

### 1.2 机器规格

- Ubuntu 24.04 Server，x86-64，**4 vCPU / 8 GB 内存 / 40 GB 磁盘起**。
  - 游戏容器默认内存上限 4 GiB，MariaDB 约 0.5 GiB，PVF 索引与镜像构建峰值 2-3 GiB。
  - 索引文件：`pvf.bin` 72 MB、`items.json` 50 MB、`item-details` 215 MB，磁盘要留够。
- 固定 IP（示例 `192.168.200.130/24`，网关 `192.168.200.2`）。
  - 若用 VMware，`/etc/netplan/01-dnf-static.yaml` 固定地址；不要和 DHCP 池冲突。

### 1.3 安装 Docker 与工具

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git jq unzip openssl python3
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /tmp/docker.gpg
sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://mirrors.aliyun.com/docker-ce/linux/ubuntu noble stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # 重新登录生效；临时可用 sg docker -c '...'
```

### 1.4 国内网络必需的三处加速

```sh
sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run", "https://dockerproxy.net"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
sudo systemctl restart docker
```

| 场景 | 变量/位置 | 值 |
| --- | --- | --- |
| 容器内拉 Go 模块 | 两个 Dockerfile 的 `ENV GOPROXY` | `https://goproxy.cn,direct` + `GOSUMDB=off` |
| Debian 基础镜像装包 | PurpleMagic Dockerfile | `deb.debian.org` → `mirrors.tuna.tsinghua.edu.cn` |
| 宿主机 apt | `/etc/apt/sources.list.d/ubuntu.sources` | 换清华/阿里源 |

> 不改 GOPROXY 会在 `go mod download` 卡死（proxy.golang.org 在境内不可达）。这是本指南唯一必须改源码的地方，见第 8 节。

---

## 2. 源码、PVF 与版本记录

```sh
sudo mkdir -p /srv/dnf/{assets,logs,backups,ops}
sudo chown -R "$(id -u):$(id -g)" /srv/dnf

cd /srv/dnf
git clone https://github.com/Cec1c/ServerS5A3.git
git clone https://github.com/Cec1c/PurpleMagic.git
cd ServerS5A3 && git log -1 --format='%H %cI'   # 记录本次部署 SHA
```

PVF 与客户端 EXE 来自 Release 附件，必须成对：

```sh
cp /path/to/Script.pvf /srv/dnf/assets/Script.pvf
sha256sum /srv/dnf/assets/Script.pvf
# 本次：4bd851752f2d02c229d89f4959571e2d1d9ac41bdd7bdf876f38c36dc22526f5
sha256sum /path/to/client/DNF.exe
# 本次：6402835223a23f9e4300c57c175d1b990b78ab0eecc46bd03fd373d0893e73f4（V214）
```

频道表用仓库自带的**完整外部 ETC**，不要从 PVF 提取：

```sh
sha256sum /srv/dnf/ServerS5A3/go-server/internal/services/dnfbridge/testdata/channel_info.etc
# 2026-11-17 基线：5630b099ef98e322806c35cec25be7c7aae699ebfbc8f16e60f1a70d12bfe7d7（120 条；超时空 244/245/246）
```

> **版本锁定**：本次部署固定在上面的提交，验收期间不跟随上游变动。截至 2026-11-14 21:55，上游 `master` 已前进到 `e5c0d97`（8 个性能提交：热读收窄、移动/战斗解析拷贝、公会与好友广播合并等），属优化类改动；验收通过后按第 10 节流程升级并重新跑 `ops-verify.sh` 即可。

---

## 3. 手动部署 A：服务端

### 3.1 打构建补丁

从 GitHub 新克隆的源码需要先打本地补丁（无域名模式必需）。补丁脚本随工具包提供：

```sh
python3 /srv/dnf/patches/apply-local-patches.py \
  --server /srv/dnf/ServerS5A3 --purplemagic /srv/dnf/PurpleMagic

# 只检查、不写入；必须 11/11
python3 /srv/dnf/patches/apply-local-patches.py \
  --server /srv/dnf/ServerS5A3 --purplemagic /srv/dnf/PurpleMagic --check
```

补丁是幂等的，重复执行安全。内容：

- `ServerS5A3/deploy/docker/Dockerfile`：加 `ENV GOPROXY=https://goproxy.cn,direct GOSUMDB=off`；
- `ServerS5A3/deploy/docker/manage.py`：`player_proxy_secret`、`public_bootstrap`、`advertise_ip`、`DNFBRIDGE_PLAYER_PROXY_SECRET`、7001 绑定 `bootstrap_bind`、`DNF_ALLOW_PUBLIC_HOST` 开关；
- `PurpleMagic/deploy/selfhost/Dockerfile`：GOPROXY + Debian 源换清华；
- `PurpleMagic/deploy/selfhost/prepare.py`：证书校验 IP 用 `-checkip`、域名用 `-checkhost`。

**每次 `git pull` 之后都要重新执行一次**（上游可能覆盖这些文件），详见 `patches/README.md`。

### 3.2 构建镜像

```sh
cd /srv/dnf/ServerS5A3
docker build -t servers5a3-local:dev -f deploy/docker/Dockerfile .
# 或：sh deploy/docker/manage.sh build
docker images servers5a3-local:dev
```

产物：镜像内 `/usr/local/bin/DNF90Server`、`DNF90Assets`（Alpine，128 MB）。
构建阶段在 `golang:1.26.5-alpine` 里编译，**宿主机不需要装 Go**。

### 3.3 生成运行配置（关键一步）

```sh
cd /srv/dnf/ServerS5A3
sh deploy/docker/manage.sh prepare \
  --pvf /srv/dnf/assets/Script.pvf \
  --channel-info go-server/internal/services/dnfbridge/testdata/channel_info.etc \
  --host-ip 192.168.200.130
```

`prepare` 会：
1. 复制 PVF 到 `runtime/docker/data/Script.pvf`；
2. 把外部频道表复制成 `runtime/docker/data/channel.override.etc`；
3. 用 `DNF90Assets` 容器解析两者，生成 `runtime/docker/data/manifest.json`（120 频道、端口、SHA256）；
4. 生成 `runtime/docker/instance.json`（连接与密钥）、`server.env`、`database.env`、`compose.json`、服务端 TOML。

生成后核对：

```sh
python3 -c "import json;m=json.load(open('runtime/docker/data/manifest.json'));print(m['channels'],m['source'],m['sha256'],len(m['ports']))"
# 120 external:channel.override.etc 5630b099... 120
```

> **2026-11-17 起源码新增强制要求**：首次 `prepare` 后必须把官方推荐预设
> `deploy/templates/docker-instance.recommended.json` 合并进 `runtime/docker/instance.json`，
> 否则青龙/黄龙/魂大会不出怪、2365 赛马闪退、双组 Buff/公会/深渊兼容项默认关闭。
> 一键脚本已自动合并；手动部署执行：

```sh
python3 - <<'PY'
import json
from pathlib import Path
inst_path = Path("runtime/docker/instance.json")
rec_path = Path("deploy/templates/docker-instance.recommended.json")
inst = json.loads(inst_path.read_text(encoding="utf-8"))
rec = json.loads(rec_path.read_text(encoding="utf-8"))
compat = {**inst.get("runtime_compatibility", {}), **rec.get("runtime_compatibility", {})}
merged = {**inst, **rec, "runtime_compatibility": compat}
inst_path.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
PY
```

> **升级旧实例注意**：新基线摘要为 `5630b099...`。如果 `runtime/docker/data/channel.override.etc`
> 还是旧表，`prepare` 会拒绝覆盖；先把它改名备份（如 `channel.override.etc.bak-日期`），
> 再执行 `prepare` 生成新表。一键脚本第 8 步已自动做这个备份。

### 3.4 改 `/srv/dnf/ServerS5A3/runtime/docker/instance.json`

合并推荐预设后，再确认这些部署相关字段（预设已带大会/Buff/公会开关）：

| 字段 | 值 | 原因 |
| --- | --- | --- |
| `joust_event_enabled` | `false` | 2365 赛马会闪退，必须关 |
| `dungeon_tournament` | `"vendor"` | 启用普通/魂大会赛程 |
| `channel_advertise_server` | `1` | 频道目录里的区服号；必须等于登录器 `ChannelServerId` |
| `channel_directory_owner_range` | `"u8"` | 不下发 >255 的频道（508），避免客户端落点崩溃 |
| `public_bootstrap` | `true` | 7001 绑 `host_ip` |
| `restart` | `"unless-stopped"` | 开机/重启自动拉起 |
| `player_admin_secret` | 32 字节 hex | 没有就 `python3 -c "import secrets;print(secrets.token_hex(32))"` 补上；GM 管理 API 用它 |

### 3.5 启动与验收

```sh
sh deploy/docker/manage.sh up      # 会再跑一次 prepare 并重建容器
sh deploy/docker/manage.sh status
curl -s http://127.0.0.1:17002/api/status
ss -lnt | grep -c '192.168.200.130:10'   # 应为 120
```

看启动日志里的生效值（必须逐项一致）：

```sh
docker logs --tail 200 servers5a3-local-server-1 | grep -o 'joust_event_enabled=[a-z]*\|joust_event_catalog_includes_2365=[a-z]*\|game_ports=[0-9]*\|advertise_server_index=[0-9]*'
# joust_event_enabled=false
# joust_event_catalog_includes_2365=false
# game_ports=120
# advertise_server_index=1
```

### 3.6 活动开关逐项核对

```sh
SECRET=$(python3 -c "import json;print(json.load(open('runtime/docker/instance.json'))['player_admin_secret'])")
curl -s -X POST http://127.0.0.1:17002/api/game/admin \
  -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
  -d '{"version":1,"action":"activities"}' | python3 -m json.tool | head -60
```

本次实际结果：开启 2520 战令、145 大富翁、350 史诗之路、2347 累计在线、331 普通签到、2208 每周签到、2370 每日签到；关闭 2365 赛马、216、2395 及其余。

> 注意：已保存的活动设置优先于环境变量。全新库没有保存值，改 env 即生效；已有库要在管理接口里 `save_activities` 保存 2365=false 再重启。

---

## 4. 手动部署 B：PurpleMagic 网关 + GM

### 4.1 准备输入

```sh
cd /srv/dnf/PurpleMagic
umask 077
mkdir -p runtime/launcher-input runtime/client-input
cp /srv/dnf/assets/Script.pvf runtime/client-input/Script.pvf
cp /path/to/client/DNF.exe  runtime/client-input/DNF.exe
```

`runtime/launcher-input/server.json`：

```json
{
  "ApiUrl": "https://192.168.200.130:8443",
  "GameHost": "192.168.200.130",
  "BootstrapPort": 7001,
  "ChannelServerId": 1,
  "MinimumLauncherVersion": "0.2.20",
  "DefaultClientDirectory": ""
}
```

> 默认 IP 模式：`ApiUrl` 用 `https://<IP>:8443`，证书要带 `IP:<IP>` SAN；`prepare.py` 已改为对 IP 用 `-checkip`、对域名用 `-checkhost`（补丁见第 8 节）。
> `ChannelServerId` 必须等于服务端 `channel_advertise_server`。

### 4.2 证书与更新签名

```sh
cd /srv/dnf/PurpleMagic
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -keyout runtime/launcher-input/local-tls-key.pem \
  -out runtime/launcher-input/local-tls.pem \
  -subj "/CN=192.168.200.130" \
  -addext "subjectAltName=IP:192.168.200.130" \
  -addext "basicConstraints=critical,CA:TRUE"
openssl x509 -in runtime/launcher-input/local-tls.pem -noout -checkip 192.168.200.130

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out runtime/launcher-input/signing-key.pem
openssl pkey -in runtime/launcher-input/signing-key.pem -pubout -out runtime/launcher-input/update-public.pem
```

证书给玩家网关（8443）和 GM（443）共用；登录器按**证书 DER 的 SHA256** 固定校验，所以自签也能用，玩家不用装根证书（只有浏览器看 GM 要手动信任一次）。
域名模式把 `IP:<IP>` 换成 `DNS:players.<域名>,DNS:gm.<域名>` 即可，`prepare.py` 会自动改用 `-checkhost` 校验。

### 4.3 生成 profile

```sh
python3 scripts/prepare_launcher_profile.py \
  --connection runtime/launcher-input/server.json \
  --client runtime/client-input \
  --certificate runtime/launcher-input/local-tls.pem \
  --public-key runtime/launcher-input/update-public.pem \
  --output runtime/launcher-input/profile.json
```

`profile.json` 内含 ApiUrl/GameHost/BootstrapPort/ChannelServerId/CertificateSha256/UpdatePublicKey/ExeSha256/PvfSha256。
**这份文件会被编译进登录器**，改了它必须重编登录器。

### 4.4 服务配置

`runtime/selfhost-settings.json`（`prepare.py` 会逐项校验）：

| 字段 | 值 |
| --- | --- |
| `gmOrigin` | `https://192.168.200.130`（HTTPS、443；IP 或域名均可） |
| `approvedProfile` / `signingPrivateKey` | 上面两个文件 |
| `pvfFile` | `runtime/client-input/Script.pvf` |
| `playerCertificate` / `playerCA` / `webCertificate` | `local-tls.pem` |
| `playerPrivateKey` / `webPrivateKey` | `local-tls-key.pem` |
| `database.registrationDsn` / `repositoryDsn` | `dnf:<database_password>@tcp(10.253.90.3:3306)/dnf_local?parseTime=true&charset=utf8mb4` |
| `database.accountTable` | `dnf90_web_accounts` |
| `database.databases` | `["dnf_local"]`，`tablePrefix` `dnf` |
| `game.upstream` | `http://127.0.0.1:17002` |
| `game.proxySecret` | `instance.json` 的 `player_proxy_secret` |
| `game.adminUrl` | `http://127.0.0.1:17002/api/game/admin`（注意不是 18111） |
| `game.adminToken` | `instance.json` 的 `player_admin_secret` |

> 数据库走 Docker 网桥地址 `10.253.90.3`，宿主机可直接路由；PurpleMagic 容器用 host 网络，所以 `127.0.0.1:17002` 可用。

### 4.5 生成私有目录并构建

```sh
python3 deploy/selfhost/prepare.py --settings runtime/selfhost-settings.json --output runtime/selfhost
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml build
```

输出目录**必须是新的**；升级时保留原 `runtime/selfhost` 不重跑初始化。

### 4.6 索引与管理表（耗时最长）

```sh
C="docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml"
$C --profile setup run --rm index-pvf
$C --profile setup run --rm index-items
$C --profile setup run --rm index-quests
$C --profile setup run --rm index-professions
$C --profile setup run --rm schema
```

4 vCPU 实测：`index-pvf` 约 10 秒；`index-items` 约 **24 分钟**（154,874 件物品，分两阶段）；quests/professions/schema 各几十秒。索引写在 `runtime/selfhost/indexes/`。

### 4.7 启动与验收

```sh
$C up -d gateway gm edge
$C ps
curl -s --cacert runtime/selfhost/tls-player/ca.pem https://192.168.200.130:8443/api/status
curl -s --cacert runtime/selfhost/tls-player/ca.pem -o /dev/null -w '%{http_code}\n' \
  https://192.168.200.130:8443/launcher/v2/bootstrap.json
```

GM：`https://192.168.200.130`，Token 在 `runtime/selfhost/admin-token.txt`。

不想开浏览器时，可以用命令行验证 GM（登录 + 查账号）：

```sh
cd /srv/dnf/PurpleMagic
TOKEN=$(cat runtime/selfhost/admin-token.txt)
CA=runtime/selfhost/tls-player/ca.pem
curl -s --cacert $CA -H 'Content-Type: application/json' \
  -d "{\"password\":\"$TOKEN\",\"remember\":true}" \
  -D /tmp/gm-h.txt -o /dev/null https://192.168.200.130/api/auth/login
grep -i '^set-cookie' /tmp/gm-h.txt      # 应看到 dfo_gm_session=...
SESS=$(sed -n 's/.*dfo_gm_session=\([^;]*\).*/\1/p' /tmp/gm-h.txt | tr -d '\r')
curl -s --cacert $CA -b "dfo_gm_session=$SESS" \
  "https://192.168.200.130/api/v1/accounts?limit=20" | head -c 400
```

返回 `{"data":[{"accountId":"dnf:10001","name":"dnftest01",...` 说明 GM → 网关 → 游戏库整条链路正常。

浏览器打开 `https://192.168.200.130/console/` 时，除了证书要手动信任一次，页面应能加载 JS/CSS（`/console/assets/index-*.js` 返回 200，约 470 KB）。

> 无域名模式不需要任何 hosts：网关、GM、登录器都直接用 `192.168.200.130`，玩家端零配置。

### 4.8 PVF 更新：不需要重编登录器

登录器运行期使用 **Hub 发布的签名 profile**（`Profile => bootstrap?.Profile ?? root`），所以换 PVF 只需更新发布状态，不用改 EXE：

1. 服务端换 PVF（备份 → 覆盖 `/srv/dnf/assets/Script.pvf` → 移走 `runtime/docker/data/Script.pvf` → `manage.sh prepare`（仍传外部频道表）→ `manage.sh up`）；
2. PurpleMagic 换 `runtime/client-input/Script.pvf`，重新生成 `profile.json`（新 `PvfSha256`）；
3. 停 gateway，执行发布状态迁移，再起 gateway：

```sh
cd /srv/dnf/PurpleMagic
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml stop gateway
python3 /srv/dnf/toolkit/tools/hub-migrate-profile.py --selfhost runtime/selfhost \
  --profile runtime/launcher-input/profile.json
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml up -d gateway
```

4. 重建索引（`index-pvf/items/quests/professions`），重启 gm；
5. 客户端替换 `Script.pvf`（下一步可接 Hub 资源发布做自动分发）。

GM 的“连接配置”只允许改 `GameHost`/`BootstrapPort`；`PvfSha256` 被刻意冻结，必须用上面的受控迁移（工具会备份 `hub/state.json`、`sequence+1`、清空旧 `content`）。

> 已实测：迁移后 bootstrap 的 `sequence` 与 `PvfSha256` 正确变化，网关正常启动；回迁后 `ops-verify.sh` 11/11。
>
> 只有改用域名时，才需要在服务器和玩家端做解析；云镜像还要注意 cloud-init 每次开机重写 `/etc/hosts`（写 `/etc/cloud/templates/hosts.debian.tmpl` 才能持久）。

---

### 4.9 更新客户端 EXE / PVF（不重编登录器）

换客户端 `DNF.exe`（或 `Script.pvf`）后，登录器提示"与测试服版本不一致"，是因为 profile 里的
`ExeSha256`/`PvfSha256` 还是旧值。服务端执行一条命令即可：

```sh
bash /srv/dnf/ops/update-client-profile.sh --exe /path/to/new/DNF.exe
# PVF 同时换了就再加 --pvf
bash /srv/dnf/ops/update-client-profile.sh --exe /path/to/new/DNF.exe --pvf /path/to/new/Script.pvf
```

脚本自动完成：

1. 备份旧 `DNF.exe`、`Script.pvf`、`profile.json`、`private/player-profile.json`；
2. 复制新文件到 `runtime/client-input/`；
3. 重新生成 `runtime/launcher-input/profile.json`（保留 QQ 绑定开关）；
4. 停 gateway → 迁移 Hub 发布状态（`sequence+1`）→ 启 gateway；
5. 拉 `bootstrap.json` 校验并输出：

```text
sequence: 6
ExeSha256: <新哈希> expected: <新哈希>
[PASS] ExeSha256
[PASS] PvfSha256
[OK] 完成：客户端重启登录器即可拉到新 profile（无需重编登录器）
```

失败时会打印 gateway 日志和完整回滚命令。玩家只需退出再打开登录器。

## 5. 手动部署 C：Windows 登录器

### 5.1 构建机要求

| 组件 | 版本 | 备注 |
| --- | --- | --- |
| Flutter | 3.47.x（Dart 3.13+） | `launcher/Flutter` 要求 `sdk ^3.13.2` |
| .NET SDK | 8.0.x | 用于 Host/Portable 的 **NativeAOT** |
| Visual Studio 2022 生成工具 | 含 C++ 桌面 + Windows SDK | AOT 链接与 Flutter windows 构建都要 |
| Git | 任意 | Flutter 需要 `git` 在 PATH |

### 5.2 准备仓库与素材

```bat
git clone https://github.com/Cec1c/PurpleMagic.git
cd PurpleMagic
mkdir runtime\launcher-input
copy <服务器上的>\profile.json runtime\launcher-input\profile.json
```

`launcher\Flutter\assets\` 需要两张图（仓库不附带）：`background.webp`（1600×1000 左右）、`announcement.webp`（1000×360 左右）。
`launcher\Flutter\windows\runner\resources\app_icon.ico` 与 `launcher\Flutter\brand\witch.png` 仓库自带。

### 5.3 构建

```bat
call D:\SDKs\flutter\bin\flutter.bat config --enable-windows-desktop
call D:\SDKs\flutter\bin\flutter.bat pub get --directory launcher\Flutter
BUILD_FLUTTER.bat --flutter D:\SDKs\flutter --dotnet D:\SDKs\dotnet8\dotnet.exe ^
  --profile-dir runtime\launcher-input --output dist\PurpleMagic-1.0.13
BUILD_PORTABLE.bat --bundle dist\PurpleMagic-1.0.13.zip --output dist\PurpleMagic.exe ^
  --dotnet D:\SDKs\dotnet8\dotnet.exe
```

产物：
- `dist\PurpleMagic-1.0.13\`：完整目录（`DNF90Launcher.exe` + `app\`）
- `dist\PurpleMagic-1.0.13.zip`：完整包
- `dist\PurpleMagic-1.0.13-app-update.zip`：自更新包（上传 Hub 用）
- `dist\PurpleMagic-1.0.13.exe`：便携入口（重命名为 `PurpleMagic.exe` 给玩家）

等价的封装脚本是第 6.6 节的 `deploy-windows.bat`（内部调用 `build-launcher.bat`）；它把上面三步串起来，并检查 Flutter、profile、素材是否齐全。
2026-11-14 在本机（Flutter 3.47.9 / .NET 8.0.427 / VS Build Tools 17.14）实测通过，产物 23 MB，构建日志见工具包运行输出。

### 5.4 只读自检（不启动游戏）

```bat
dotnet run --project launcher\Probe -- runtime\launcher-input\profile.json --channel-only
```

期望两行 PASS：`TLS certificate pin and remote status`、`native channel bootstrap: server 1; 93 rows; 3 game ports`。

### 5.5 交给玩家

无域名模式下玩家不需要改 hosts，分发包只放两样：

```text
PurpleMagic.exe          便携登录器（改了 profile 必须重发）
使用说明.txt              登录步骤与常见问题
```

> 只有改用域名模式时才需要附带 hosts 脚本（纯 ASCII 文本，避免 cmd 代码页导致解析失败）。

### 5.6 自更新与后续给登录器加功能

登录器自带签名自更新：网关 Hub 发布 `launcher` 字段后，旧版启动时会下载、校验 SHA256、原子替换 `app\` 并重启，失败自动回滚（`.bak`）。

发布新版本：

1. 改 `launcher/Flutter` 或 `launcher/Engine`；
2. 三处版本号一起 +1（构建脚本第 7 步会提示输入并自动修改）：
   - `<源码目录>\launcher\Engine\LauncherEngine.cs` 的 `public const string VersionText`
   - `<源码目录>\launcher\Host\Launcher.Host.csproj` 的 `<Version>`
   - `<源码目录>\launcher\Flutter\pubspec.yaml` 的 `version:`
3. `build-launcher.bat ... dist\PurpleMagic-<版本>`；
4. 发布更新包：

```sh
TOKEN=$(cat /srv/dnf/PurpleMagic/runtime/selfhost/admin-token.txt)
CA=/srv/dnf/PurpleMagic/runtime/selfhost/tls-player/ca.pem
curl -s --cacert $CA -X POST https://<IP>/admin/api/bundle/<新版本> \
  -H "Authorization: Bearer $TOKEN" --data-binary @PurpleMagic-<新版本>-app-update.zip
```

玩家下次启动自动更新。版本必须严格递增，更新包必须包含 `dnf90.exe`、`dnf90.core.exe`、`flutter_windows.dll`、`data/app.so`、`data/icudtl.dat`。

> 本次已实测：1.0.12 → 发布 1.0.13 → 旧客户端自动更新成功（`.launcher-update-result.json` 记录 `succeeded:true`）。细节见 `研究-登录器更新与PVF校验.md`。

---

## 6. 交互式一键部署

### 6.1 上传四个文件，运行 90cn一键部署.sh

把四个文件上传到服务器 **`/home/ubuntu/DNF90/`**（按你的用户名替换 `ubuntu`）：

```powershell
# 目录不存在时先建（scp 不会自动创建目标目录）
ssh ubuntu@<服务器IP> "mkdir -p /home/ubuntu/DNF90"
scp 90cn一键部署.sh DNF.exe Script.pvf DNF90-部署工具包.zip ubuntu@<服务器IP>:/home/ubuntu/DNF90/
```

> `90cn一键部署.sh` 也可以放在别处运行（如家目录），它内部固定检查 `/home/<用户>/DNF90/`，目录不存在会自动创建。

> `90cn一键部署.sh` 就在工具包里；第一次部署时需要单独把它一起传上去（它负责解压工具包）。

登录服务器执行：

```sh
bash 90cn一键部署.sh
```

脚本会依次做：

1. 检查 `/home/ubuntu/DNF90/`（不存在会自动创建）里是否有 `DNF.exe`、`Script.pvf`、`DNF90-部署工具包.zip`，缺哪个会打印 `scp` 命令后退出；
2. 创建 `/srv/dnf/{assets,logs,backups,ops,packages,probe}`（没有权限时用 `sudo` 并 `chown` 给当前用户）；
3. 把 `DNF.exe`、`Script.pvf` 复制到 `/srv/dnf/assets/`；
4. 把工具包复制到 `/srv/dnf/` 并解压到 `/srv/dnf/toolkit/`；
5. `chmod +x` 后自动进入 `deploy-oneclick.sh` 的交互界面。

之后第 8 步的 PVF、第 10 步的 `DNF.exe` 都会从 `/srv/dnf/assets/` 自动取，**不再需要中途手动上传**。

> 也可以跳过包装脚本，自己解压工具包后直接 `bash deploy-oneclick.sh`；只要 `DNF.exe` / `Script.pvf` 在 `/home/<用户>/DNF90/`、家目录或 `/srv/dnf/assets/`，部署脚本会自动复制。

### 6.2 主界面：按回车依次执行，过程中就地询问

运行后先打印 15 步计划，然后：

```text
直接按回车 = 依次执行 1→15（过程中就地询问必要的选择）；输入编号 = 只执行该步；s = 提前设置（可选）；q = 退出
>
```

- **直接回车**：从第 1 步依次跑到第 15 步。需要你决定的地方会**就地停下来问**，回答后继续，不会返回菜单：
  - 第 2 步：是否配置 Docker 镜像加速（`Y/n`）；
  - 第 3 步：源码方式（`1` 本地 / `2` Git）；选本地会打印上传路径和 `scp` 示例，并等你上传完按回车重新检测；
  - 第 4 步：部署方式（IP / 域名）与地址；已有配置会先问"使用当前地址？"，答 `n` 才重新输入；
  - 第 6 步：如果存在功能补丁，逐个询问是否应用（`y/N`）；
  - 其余步骤全自动。
- **输入编号 1~15**：只执行该步，用于排错或补跑；
- **s**：可选，提前把源码/地址/镜像/功能补丁设好；设好后回车执行就不再询问；
- **q**：退出。

### 6.3 每一步会问什么

| 步骤 | 就地询问 | 默认 / 说明 |
| --- | --- | --- |
| 1 环境 | 无 | 缺 Docker/工具会自动安装 |
| 2 镜像加速 | 是否配置？ | `Y`；已有 daemon.json 时只检查不覆盖 |
| 3 源码 | 1 本地 / 2 离线包 / 3 GitHub ZIP / 4 Git | ZIP 走 codeload（断点续传）；选 ZIP/Git 后再选仓库：1 Cec1c（原作者）/ 2 TenThousandHippies（fork） |
| 4 地址 | IP/域名；IP 合法性；NAT 拆分；确认当前地址 | 已有配置默认"使用当前地址" |
| 5 必要补丁 | 无 | 11 项，失败即停 |
| 6 功能补丁 | 逐个 y/N | 没有补丁时直接跳过 |
| 7-15 | 无 | 构建、prepare、启动、配置、索引、网关、自检 |

### 6.4 各步骤成功标志

| 步骤 | 做什么 | 成功标志 |
| --- | --- | --- |
| 1 | 安装/检查 Docker 与工具 | `环境已就绪` 或 Docker 版本 |
| 2 | 配置镜像加速 | `Docker 镜像加速已存在` / `已写入` |
| 3 | 准备源码 | `源码就绪`（Git 会 clone/pull，本地会等上传） |
| 4 | 地址 | `部署方式：ip ...` |
| 5 | 11 项必要补丁 | `11/11 patches present` |
| 6 | 功能补丁 | `功能补丁完成` 或 `未选择…跳过` |
| 7 | 构建服务端镜像 | `servers5a3-local:dev 构建完成` |
| 8 | prepare | `prepare 完成`（PVF 自动复制；自动合并 `docker-instance.recommended.json`，含 `dungeon_tournament=vendor`、`buff_group_sync=on` 等） |
| 9 | 启动游戏服务 | 账号 API `{"ok":true,...}` |
| 10 | PurpleMagic 配置 | `profile 与 settings 已生成`（`DNF.exe` 自动从 `~/DNF90/` 或 `assets/` 复制） |
| 11 | 生成网关运行目录 | `runtime/selfhost 已生成` |
| 12 | 构建网关镜像 | `purplemagic:local 构建完成` |
| 13 | 索引与管理表 | 五个子步骤完成（`index-items` 最慢），完成后自动重启 gm 加载新索引 |
| 14 | 启动网关 | 三个容器 running |
| 15 | 自检 | `VERIFY_OK` + 管理员 Token |

### 6.5 源码获取：ZIP 下载 / Git / 离线包

**仓库选择**：选 `3 GitHub ZIP` 或 `4 Git` 后会再问一次：

```text
  1) Cec1c（原作者）
  2) TenThousandHippies（fork）
请选择源码仓库 [1]:
```

对应地址：

```text
Cec1c:              https://github.com/Cec1c/ServerS5A3
                    https://github.com/Cec1c/PurpleMagic
TenThousandHippies: https://github.com/TenThousandHippies/ServerS5A3
                    https://github.com/TenThousandHippies/PurpleMagic
```

ZIP 下载会自动尝试 `master` / `main` 两种分支名；Git 拉取失败时也会换分支重试。


第 3 步有四种方式，按网络情况选：

| 选项 | 做法 | 适用 |
| --- | --- | --- |
| 1 本地源码 | 自己 `scp -r` 上传两份源码 | 源码已在手边 |
| 2 离线包 | 把 `ServerS5A3.zip`、`PurpleMagic.zip` 放到 `/srv/dnf/packages/` | 完全离线 |
| 3 GitHub ZIP | 从 `codeload.github.com` 下载 zip，支持断点续传（`curl -C -`），下载完自动解压 | **推荐**，比 git 稳 |
| 4 Git 拉取 | `git init` + `git fetch --depth 1`，关闭低速中止 | 想要 `.git` 历史 |

ZIP 地址：

```text
https://codeload.github.com/Cec1c/ServerS5A3/zip/refs/heads/master
https://codeload.github.com/Cec1c/PurpleMagic/zip/refs/heads/main
```

下载失败会自动重试；已下载的 `.part` 会在下次尝试时续传。下载后落到 `/srv/dnf/packages/`，解压到 `/srv/dnf/ServerS5A3`、`/srv/dnf/PurpleMagic`，已有源码保留。

Git 方式（选项 4）说明：`ping github.com` 通不代表 git 能拉下来，git 默认在"30 秒内低于 1000 B/s"时中止并报 `Operation too slow`。脚本已关闭低速中止（`GIT_HTTP_LOW_SPEED_LIMIT=0`）、单次上限 3600 秒、失败重试 3 次；可用 `GIT_FETCH_TIMEOUT=7200` 加大。Git 不支持断点续传，网络很差时优先用 ZIP。

### 6.6 中断、续跑与幂等

- 任一步失败：回到主界面，输入失败步骤的编号单独重跑；
- 第 8 步重复执行会重新生成配置；PVF 与运行副本不一致时自动备份旧文件；
- 第 10 步重复执行会备份旧 profile 再生成；证书存在时会询问是否重签；
- 第 11 步重复执行会归档旧 `runtime/selfhost`（`selfhost-bak-*`），不会丢数据；
- 第 13 步会复用已生成的索引，只有 PVF 变了才需要重建。

### 6.7 完整会话示例（IP 模式）

```text
$ bash deploy-oneclick.sh
------------------------------------------------------------
DNF90 部署计划  —  2026-11-15 21:00:00
------------------------------------------------------------
  1  环境检查与安装        已就绪
  2  镜像加速                 yes
  3  准备源码                 未选择
  4  部署地址                 未设置
  ...
 15  自检并输出 Token
------------------------------------------------------------
直接按回车 = 依次执行 1→15；输入编号 = 只执行该步；s = 修改设置；q = 退出
> s
...
  1) 源码方式（当前：未选择）
...
请选择 [5]: 1
  1) 本地源码 ...
  2) Git 拉取 ...
请选择 [2]: 2
[OK] 源码方式：git
...
> 2
  1) IP 直连（无域名，推荐）
  2) 域名访问
请选择 [1]: 1
本机网卡 IPv4：
  enp0s17    192.168.200.130/24
...
请输入服务端 IP（玩家可访问的地址） [192.168.200.130]:
[OK] 部署方式：ip  BIND_IP=192.168.200.130  公网/玩家地址=192.168.200.130
...
> （直接回车）
开始依次执行 1→15 ...
[步骤 3] ... 源码就绪
...
[OK] 全部步骤完成。
管理员 Token：xxxxxxxx
```

### 6.8 Windows 侧交互脚本

```bat
deploy-windows.bat
```

主界面按回车 = **依次执行 1→7**，只在需要输入时停下；输入编号可单步执行：

| 编号 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 环境检查 | 自动找 Flutter / .NET 8 / VS C++ / Git / Python，找不到才问路径 |
| 2 | 选择源码 | 默认 GitHub ZIP，压缩包存到 `D:\dnf-work\src\PurpleMagic-main.zip`；先选仓库；旧源码归档到 `build\archive`（3 份）；新源码缺 profile.json 时**要求手动输入本机路径**，不再从旧源码自动复制 |
| 3 | 必要补丁 | `patches\windows\required\<名称>\apply.ps1`；没有时提示"无需补丁" |
| 4 | 功能补丁 | `patches\windows\features\<名称>\apply.ps1`，逐个 y/N |
| 5 | 地址与 profile | 地址与 `profile.ApiUrl` 已匹配则跳过；否则询问 IP/域名 |
| 6 | 开启 QQ 绑定 | 把 `profile.json` 的 `EnableQQBinding` 置为 `true` |
| 7 | 构建登录器 | 素材确认；旧输出归档到 `dist\archive`；构建完显示成品路径，并询问是否复制为 `D:\dnf-work\测试部署\游戏客户端\PurpleMagic.exe`（覆盖前自动备份） |
| 8 | 发布自更新包 | 问 y/N；需要版本号与管理员 Token 文件 |

选择保存在 `windows-build.json`，下次运行自动带出。

#### 发布自更新包做了什么

第 8 步（或构建后的询问）会把 `dist\<输出>-app-update.zip` 用 HTTPS 上传到**网关 Hub**：

```text
POST https://<服务器地址>/admin/api/bundle/<版本号>
Authorization: Bearer <admin-token>
```

- **哪台服务器**：你在第 5 步填的地址（如 `1.15.60.33`），443 端口经 nginx 转发到 gateway；
- **存到哪**：服务器上 `/srv/dnf/PurpleMagic/runtime/selfhost/hub/bundles/<sha256>.zip`（容器内 `/data/hub/bundles/`），同时更新 `/srv/dnf/PurpleMagic/runtime/selfhost/hub/state.json` 的 `published.launcher`（版本/大小/SHA256）并让 `sequence + 1`；
- **谁会用**：玩家下次启动登录器时拉 `/launcher/v2/bootstrap.json`，发现新版本就下载、校验 SHA256、替换 `app\` 并重启；
- **不是**直接改游戏客户端目录，也不影响服务端；版本号必须比当前发布的版本大，否则返回 409。

Token 文件在服务器：`/srv/dnf/PurpleMagic/runtime/selfhost/admin-token.txt`。

#### QQ 绑定说明

- `EnableQQBinding` 是**登录器功能开关**，来自构建时嵌入的 `profile.json`：第 6 步写入后重新构建才生效；
- `RequireQQBinding` 是**强制登录绑定**，来自网关签名的 bootstrap profile，属于服务端策略；
- 绑定码校验还需要网关的 QQ 机器人配置（GM 的 QQ 设置）；没配机器人时入口会出现，但绑定码无法完成。

### 6.9 边界

- 脚本不做数据库迁移；迁移见 7.5。
- 索引耗时与磁盘占用见 1.2。
- NAT 云主机需要安全组/端口映射；脚本只负责绑定与通告地址。
- 域名模式仍需要证书覆盖域名；IP 模式证书用 `IP:<地址>` SAN。

---

### 6.10 全新部署顺序（重装服务器 + 重建登录器）

1. 服务器重装 Ubuntu 24.04，**尽量保持原 IP**（换 IP 要重签证书、重编登录器）；
2. 上传 4 个文件到 `/home/<用户>/DNF90/` 并运行 `90cn一键部署.sh`，第 3 步选 `3 GitHub ZIP`（Cec1c 或 TenThousandHippies），第 4 步填 IP；
3. 脚本自动：装 Docker → 拉源码 → 11 项补丁 → 构建 → prepare（新 120 频道基线）→ 合并推荐预设 → 起服务 → 证书/profile → 索引 → 网关 → 自检；
4. 记录输出的 **admin token**，确认 `ops-verify.sh` 全 PASS；
5. 把服务器的 profile 拉到 Windows：

```powershell
scp ubuntu@<IP>:/srv/dnf/PurpleMagic/runtime/launcher-input/profile.json D:\dnf-work\profile.json
```

6. Windows 运行 `deploy-windows.bat`：第 2 步选源码（ZIP 或已有目录），缺 profile 时会要求输入第 5 步的路径；第 5 步填 IP；第 6 步 QQ 绑定；第 7 步构建；
7. 把 `dist\PurpleMagic-custom.exe` 改名为 `PurpleMagic.exe`，放到客户端上层目录并分发给玩家；
8. **首次不要依赖自更新**：重装后签名密钥/证书都是新的，旧登录器无法信任新 Hub，必须手动换新 EXE；之后换客户端 EXE/PVF 用 `/srv/dnf/ops/update-client-profile.sh`，玩家重启登录器即可；
9. 发布登录器新版本前，`LauncherEngine.VersionText` 必须**大于** Hub 已发布版本，否则会循环提示更新。

### 6.11 登录器版本号（防无限更新）

规则只有一条：

```text
Hub 发布版本号  ==  构建时写入的 VersionText  >  玩家当前版本
```

只要 Hub 发布版本大于新包自己的 `VersionText`，客户端装完还会再更新，形成“无限更新/无限重启”。

**构建脚本已自动处理**：第 7 步开始时会显示当前版本并要求输入新版本，自动修改这三处并打印 old → new：

| 文件（完整路径，源码目录默认 `D:\dnf-work\build\pm-src\PurpleMagic-main`） | 修改内容 |
| --- | --- |
| `<源码目录>\launcher\Engine\LauncherEngine.cs` | `public const string VersionText = "x.y.z";` |
| `<源码目录>\launcher\Host\Launcher.Host.csproj` | `<Version>x.y.z</Version>` |
| `<源码目录>\launcher\Flutter\pubspec.yaml` | `version: x.y.z+N`（N 自动 +1） |

发布时填的版本号必须与构建版本完全一致。

如果已经发错了版本，两条路：

1. 构建一个**更高**版本（如 Hub 是 1.0.14，就构建并发布 1.0.15）；
2. 清空 Hub 的登录器发布（停止自动更新）：

```sh
cd /srv/dnf/PurpleMagic
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml stop gateway
python3 - <<'PY'
import json
p = 'runtime/selfhost/hub/state.json'
d = json.load(open(p))
d['published']['launcher'] = None
d['published']['sequence'] += 1
json.dump(d, open(p, 'w'), ensure_ascii=False, indent=2)
PY
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml up -d gateway
```

### 6.12 更新缓存与磁盘清理

无限更新会不断堆积这些目录（都在 `%LocalAppData%\DNF90Launcher` 下）：

| 路径 | 内容 |
| --- | --- |
| `bundle-downloads\` | 每次更新下载的 `-app-update.zip` |
| `portable\<hash>\.updates\` | 更新事务、旧版备份 `previous\`、失败残留 `failed-*` |
| `portable\<hash>\app\` | 当前安装的登录器文件 |
| `bootstrap.json` | 缓存的签名发布信息 |

清理（先完全退出登录器）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File clean-launcher-cache.ps1
# 连安装缓存一起清（下次启动从 PurpleMagic.exe 重新解压）：
powershell -NoProfile -ExecutionPolicy Bypass -File clean-launcher-cache.ps1 -All
```

脚本会打印释放了多少 MB；也会删掉 `instance.lock`、`.launcher-update-result.json`，解除“上次更新失败”的抑制。

### 6.13 替换客户端 EXE / PVF

要保证三份文件一致：

1. 玩家客户端：`<客户端目录>\client\DNF.exe`、`Script.pvf`
2. 服务端：`/srv/dnf/PurpleMagic/runtime/client-input/DNF.exe`、`Script.pvf`
3. 服务端据此生成的 `/srv/dnf/PurpleMagic/runtime/launcher-input/profile.json` 里的 `ExeSha256/PvfSha256`

**服务端操作（脚本）**：

```sh
scp DNF.exe ubuntu@<IP>:/tmp/
scp Script.pvf ubuntu@<IP>:/tmp/        # 换 PVF 时
ssh ubuntu@<IP>
bash /srv/dnf/ops/update-client-profile.sh --exe /tmp/DNF.exe --pvf /tmp/Script.pvf
```

脚本自动：备份 → 复制到 `runtime/client-input` → 重生成 `runtime/launcher-input/profile.json` → 停 gateway → 迁移 `/srv/dnf/PurpleMagic/runtime/selfhost/hub/state.json` → 启 gateway → 校验 `[PASS] ExeSha256 / PvfSha256`。

**Windows 一键操作（本机替换 + 上传 + 远程更新）**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File update-client-files.ps1 `
  -Exe "D:\新客户端\DNF.exe" -Pvf "D:\新客户端\Script.pvf" `
  -ClientDir "D:\dnf-work\测试部署\游戏客户端\client" `
  -ServerHost 1.15.60.33
```

**玩家侧**：完全退出登录器再打开即可；只需要换 EXE 的情况（没换签名/证书）不用重发登录器。

**回滚**：客户端 `DNF.exe.bak-<时间>`；服务端 `runtime/client-input/DNF.exe.bak-<时间>` 和 `runtime/launcher-input/profile-<时间>.json`，重新执行迁移脚本即可。

## 7. 迁移到公网（无域名 / IP 模式）

迁移 = 在公网机器上按第 1-6 节重新部署一遍，只改下面这些"信息"。**服务端程序、镜像、索引都不用改**。

### 7.1 必须改的 5 个地方

| # | 文件 | 字段 | 本地值 → 公网值 |
| --- | --- | --- | --- |
| 1 | `ServerS5A3/runtime/docker/instance.json` | `host_ip` | `192.168.200.130` → 公网 IP（频道通告地址就是它） |
| 2 | 同上（重新 prepare 的参数） | `--host-ip` | 同上，必须重跑 `prepare` 才会重写 `compose.json`/`server.env` |
| 3 | `PurpleMagic/runtime/launcher-input/server.json` | `ApiUrl` | `https://192.168.200.130:8443` → `https://<公网IP>:8443` |
| 4 | 同上 | `GameHost` | 公网 IP（玩家直连的游戏地址） |
| 5 | `PurpleMagic/runtime/selfhost-settings.json` | `gmOrigin` | `https://192.168.200.130` → `https://<公网IP>` |

证书不用换成域名证书，但 **IP 变了就必须重签**（SAN 里是旧 IP）；重签后 `CertificateSha256` 变化，登录器必须重编。

### 7.2 重新生成与重建的顺序

```sh
# 1) 服务端：换 host_ip 后重新 prepare + up（重写频道表通告地址与端口绑定）
cd /srv/dnf/ServerS5A3
sh deploy/docker/manage.sh prepare --pvf /srv/dnf/assets/Script.pvf \
  --channel-info go-server/internal/services/dnfbridge/testdata/channel_info.etc \
  --host-ip <公网IP>
sh deploy/docker/manage.sh up

# 2) 证书按新 IP 重签，再重新生成 profile
cd /srv/dnf/PurpleMagic
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -keyout runtime/launcher-input/local-tls-key.pem -out runtime/launcher-input/local-tls.pem \
  -subj "/CN=<公网IP>" -addext "subjectAltName=IP:<公网IP>" \
  -addext "basicConstraints=critical,CA:TRUE"
python3 scripts/prepare_launcher_profile.py --connection runtime/launcher-input/server.json \
  --client runtime/client-input --certificate runtime/launcher-input/local-tls.pem \
  --public-key runtime/launcher-input/update-public.pem \
  --output runtime/launcher-input/profile-<公网IP>.json

# 3) 网关/GM：用新目录重新 prepare.py（不要覆盖旧目录），再 build/up
python3 deploy/selfhost/prepare.py --settings runtime/selfhost-settings.json --output runtime/selfhost-public

# 4) Windows：用新 profile 重新构建登录器（profile 编译进 DNF90.Core.exe）
```

### 7.3 公网要放的端口

| 端口 | 协议 | 说明 |
| --- | --- | --- |
| 7001 | TCP | 频道引导 |
| 10006-10508 | TCP | 只放行实际启用的频道端口（120 个） |
| 30000-30063 | UDP | 组队 |
| 8443 | TCP | 玩家 HTTPS |
| 443 | TCP | GM 网页 |
| 17002/18111/18444/18080/18081 | TCP | **不要**对公网开放，保持 `127.0.0.1` |

云厂商安全组 + 主机防火墙（ufw/iptables）两层都要放行。

### 7.4 证书与访问方式

- 证书 SAN 是 `IP:<公网IP>`；换 IP 必须重签，重签后必须重发登录器。
- 玩家访问 `https://<公网IP>:8443`（登录器）与 `https://<公网IP>`（GM 浏览器），GM 首次要手动信任自签证书。
- 登录器不需要装根证书：它按证书 DER 的 SHA256 固定校验。

### 7.5 存档迁移

```sh
# 旧机
bash /srv/dnf/ops/ops-backup.sh
# 新机：先按第 3 节起空库，再导入
gunzip -c dnf_local-*.sql.gz | docker exec -i servers5a3-local-db-1 mariadb -uroot -p<root密码> dnf_local
```

同时迁移 `PurpleMagic/runtime/selfhost/{gm,hub,releases,private,tls-*}` 与 `admin-token.txt`；福利规则与领取回执在数据库里，程序目录只放会话/队列/发布状态。

> 频道表通告地址来自 `host_ip`，只改防火墙不改 `host_ip` 时玩家仍然会连到内网地址，这是最常见的迁移故障。

### 7.6 可选：改用域名

1. 两个 A 记录：`players.<域名>`、`gm.<域名>` → 公网 IP。
2. `server.json` 的 `ApiUrl` 改 `https://players.<域名>:8443`，`gmOrigin` 改 `https://gm.<域名>`。
3. 证书 SAN 换成 `DNS:players.<域名>,DNS:gm.<域名>`，`prepare.py` 会自动改用 `-checkhost` 校验。
4. 重跑 `prepare.py`、重生成 profile、重编登录器；玩家端需能解析这两个域名（公网 DNS 或 hosts）。

---

## 8. 本地补丁清单（升级源码后要重新打）

补丁统一由 `patches/apply-local-patches.py` 维护，11 项，逐条说明见 `patches/README.md`。

| 文件 | 改动 | 不打会怎样 |
| --- | --- | --- |
| `ServerS5A3/deploy/docker/Dockerfile` | `FROM` 后加 `ENV GOPROXY=...` | `go mod download` 卡死 |
| `ServerS5A3/deploy/docker/manage.py` | 默认配置加 `player_proxy_secret`、`public_bootstrap`、`advertise_ip` | 代理身份/7001 不可达/无法公网通告 |
| 同上 | 下发 `DNFBRIDGE_PLAYER_PROXY_SECRET` | 网关无法证明玩家真实 IP |
| 同上 | 7001 改绑 `bootstrap_bind` | Windows 客户端连不上 |
| 同上 | `DNFBRIDGE_SERVER_IP` 支持 `advertise_ip` | 云主机 NAT 场景通告错地址 |
| 同上 | `DNF_ALLOW_PUBLIC_HOST=1` 放开 `--host-ip` | 公网 IP 直接绑网卡时被拒 |
| `PurpleMagic/deploy/selfhost/Dockerfile` | GOPROXY + Debian 清华源 | 镜像构建卡住 |
| `PurpleMagic/deploy/selfhost/prepare.py` | IP 用 `-checkip` / 域名用 `-checkhost` | 纯 IP 部署被证书校验拒绝 |
| 登录器素材 | `background.webp`、`announcement.webp` | 构建脚本直接报错退出 |

升级流程：

```sh
cd /srv/dnf/ServerS5A3 && git pull --ff-only
cd /srv/dnf/PurpleMagic && git pull --ff-only
python3 /srv/dnf/patches/apply-local-patches.py \
  --server /srv/dnf/ServerS5A3 --purplemagic /srv/dnf/PurpleMagic
python3 /srv/dnf/patches/apply-local-patches.py \
  --server /srv/dnf/ServerS5A3 --purplemagic /srv/dnf/PurpleMagic --check   # 必须 11/11
```

出现 `anchor not found` 表示上游改了对应文件：按 `patches/README.md` 手工补上再继续，不要跳过补丁直接构建。

---

## 9. 验收清单

### 9.1 自动化

```sh
bash /srv/dnf/ops/ops-verify.sh
# 期望：全部 PASS，最后一行 VERIFY_OK
# 装了 dotnet + 探测器时 11 项；否则频道握手一项 SKIP，10 项 PASS
```

覆盖：容器健康、17002、120 频道端口、7001、2365 关闭、8443 状态、bootstrap、频道握手。
脚本从 `instance.json` 读取 `host_ip` 判断端口，不写死地址。

### 9.2 游戏内（玩家侧）

1. 直接打开 `PurpleMagic.exe`（无域名模式不需要 hosts）。
2. 选择客户端目录（含 `DNF.exe`、`Script.pvf`）。
3. 注册账号 → 登录 → 看到频道列表。
4. 选普通频道 → 建角色 → 进城 → 移动/对话。
5. 接任务 → 进副本 → 打完结算。
6. 回城看经验/物品/任务。
7. 退出游戏 → 重登 → 角色与进度还在。
8. 两个账号验证组队与进图同步（UDP 30000-30063）。

可选交叉验证：GM 里查该账号，`characterCount` 应从 0 变为 1，说明角色确实落库（GM 与游戏库同源）。

### 9.3 存档侧抽查

```sh
PW=$(grep MARIADB_PASSWORD /srv/dnf/ServerS5A3/runtime/docker/database.env | cut -d= -f2)
docker exec servers5a3-local-db-1 mariadb -udnf -p"$PW" dnf_local -e \
  "select account,id from dnf90_web_accounts; select count(*) from dnf_characters;"
```

---

## 10. 备份、更新、回退

| 操作 | 命令 |
| --- | --- |
| 手动备份 | `bash /srv/dnf/ops/ops-backup.sh`（库 + 配置 + 频道表 + PurpleMagic 私有数据 + SHA256；自动清理 14 天前旧备份） |
| 每日自动备份 | `dnf-backup.timer` 每天 04:10 执行同一脚本（`systemctl list-timers dnf-backup.timer` 查看，`journalctl -u dnf-backup` 看日志） |
| 恢复库 | 见下方「恢复已测步骤」 |
| 启停 | `ops-start.sh` / `ops-stop.sh` |
| 状态/日志 | `ops-status.sh`、`ops-logs.sh server\|gateway\|gm\|all` |
| 更新服务端 | `git pull --ff-only` → `manage.sh build` → `manage.sh up`（浅克隆先 `git fetch --unshallow`） |
| 回退服务端 | `docker tag <旧镜像ID> servers5a3-local:dev` → `manage.sh up` |
| 更新网关 | `git pull` → `compose build` → `up -d gateway gm edge`，保留 `runtime/selfhost` |
| 回退网关 | 用旧镜像 tag 重建；`gm/`、`hub/`、`releases/` 数据不动 |

数据库恢复是独立操作：先停游戏服务，恢复后再起，避免写入覆盖。

### 恢复已测步骤（2026-11-14 实测）

`manage.sh down` 会把数据库容器一起移除（数据卷保留），所以恢复时要**先把 db 容器起回来**再导入：

```sh
# 1) 停服务（游戏 + 网关）
cd /srv/dnf/ServerS5A3 && sh deploy/docker/manage.sh down
cd /srv/dnf/PurpleMagic && docker compose --env-file runtime/selfhost/compose.env \
  -f deploy/selfhost/compose.yaml stop

# 2) 只起数据库并等健康
cd /srv/dnf/ServerS5A3
docker compose -p servers5a3-local -f runtime/docker/compose.json up -d db
watch -n2 "docker inspect -f '{{.State.Health.Status}}' servers5a3-local-db-1"   # 变成 healthy 再继续

# 3) 重建库并导入（用最新的备份）
ROOTPW=$(grep '^MARIADB_ROOT_PASSWORD=' runtime/docker/database.env | cut -d= -f2)
DUMP=$(ls -t /srv/dnf/backups/dnf_local-*.sql.gz | head -1)
docker exec servers5a3-local-db-1 mariadb -uroot -p"$ROOTPW" -e \
  "DROP DATABASE IF EXISTS dnf_local; CREATE DATABASE dnf_local CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
gunzip -c "$DUMP" | docker exec -i servers5a3-local-db-1 mariadb -uroot -p"$ROOTPW" dnf_local

# 4) 起服务并自检
sh deploy/docker/manage.sh up
cd /srv/dnf/PurpleMagic
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml up -d gateway gm edge
bash /srv/dnf/ops/ops-verify.sh
```

实测结果：325 张表恢复、三个测试账号仍在、`ops-verify.sh` 11/11 通过。
恢复前建议先 `ops-backup.sh` 留一份当前状态；导入期间不要启动游戏服务。

---

## 11. 常见问题

**日志里的 `INFO dnf90 gm item index cache unusable ... items.json: no such file or directory` 是错误吗？**

不是。这是 GM 在 `items.json` 还没生成时启动打的 INFO：先启动、后建索引的正常顺序。第 13 步建完索引后脚本会自动重启 gm 加载；手动部署时索引完成后执行：

```sh
cd /srv/dnf/PurpleMagic
docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml restart gm
```



| 症状 | 原因/处理 |
| --- | --- |
| `go mod download` 卡住 | Dockerfile 没加 GOPROXY；或 goproxy.cn 不可达 |
| 镜像拉不下来 | `/etc/docker/daemon.json` 没配 registry-mirrors，或重启 docker |
| 7001 只有 127.0.0.1 | `instance.json` 没设 `public_bootstrap: true`，或没重跑 `up` |
| 客户端登录提示网络错误 | 确认虚拟机开机、`curl --cacert ... https://<IP>:8443/api/status` 正常 |
| 频道列表空/进不去 | `ChannelServerId` 与 `channel_advertise_server` 不一致；或频道端口未放行 |
| 频道 508 导致崩溃 | `channel_directory_owner_range` 不是 `u8` |
| GM 管理接口 404 | `player_admin_secret` 为空；或 `game.adminUrl` 填成了 18111 |
| `prepare.py` 报证书/域名错误 | `ApiUrl` 必须是 8443 的域名；证书 SAN 要覆盖；私钥与证书要配对 |
| 索引很慢 | `index-items` 在 4 vCPU 上约 24 分钟，属正常；看容器 CPU 是否在跑 |
| 登录器提示客户端不匹配 | `profile.json` 的 ExeSha256/PvfSha256 与实际客户端不一致 |
| 选频道卡住 | 旧 `DNF.cfg` 频道残留，用登录器「重置本机游戏配置」 |
| 重启后网关报 `management database unavailable` | 网关比 MariaDB 先起，`restart: unless-stopped` 会自愈；等 1-3 分钟，仍不行再 `docker compose ... restart gateway` |
| 改用域名后重启解析不到 | cloud-init 重写了 `/etc/hosts`；把该行加进 `/etc/cloud/templates/hosts.debian.tmpl`（见 4.7 节） |

---

## 12. 验收记录

### 12.0 无域名（IP）模式整改（2026-11-15）

- 网关/GM/登录器改为 IP 直连：`ApiUrl=https://192.168.200.130:8443`、`gmOrigin=https://192.168.200.130`。
- 证书改为 `IP:192.168.200.130` SAN，`CertificateSha256=1027c0267dbcd9f5a9eb651e6e1a48578ffb8aadc16c85ba0fda25b06740bc4f`。
- `prepare.py` 增加 IP 感知校验；玩家端不再需要 hosts。
- 验收：`ops-verify.sh` 11/11，GM 登录与查账号正常，Probe 频道握手通过，桥接日志 `login token bound game session`。
- 登录器用新 profile 重新构建（内嵌 ApiUrl/证书指纹已核对），玩家端不再需要 hosts；旧域名模式文件归档在 `runtime/backup-domain-*`。

### 12.1 首次部署验收（2026-11-14）

- **部署实例**：192.168.200.130，Ubuntu 24.04.5，服务端 44e3482，PurpleMagic 216d5888，登录器 1.0.13。
- **用户游戏内确认**：登录器注册新账号 → 登录 → 选频道 → 建角色 → 进副本 → 退出重登，确认无误。
- **数据库证据**：账号 	est001（dnf:10004）；角色 龙骑士，Lv8，exp 34344（dnf_characters）。
- **服务端日志证据**：
  - dnfbridge login token bound game session：ccount_id=dnf:10004，客户端令牌被服务端校验并绑定会话；
  - game-dungeon-select-party-context：channel_id=10、dungeon_id=9，进图选择与会话上下文正常；
  - game connection accepted：game_port=10010/10011/10012，频道端口连接正常。
- **自动验收**：ops-verify.sh 11 PASS / 0 FAIL（容器、账号 API、120 频道端口、7001、2365 关闭、8443、bootstrap、原生频道握手）。
- **运维实测**：备份→恢复→复服（325 表、账号保留）、整机冷启动自愈、每日 04:10 自动备份、全新机器一键部署（33 分钟）。

---

## 13. 常用命令详解

| 命令 | 作用 | 怎么运行 | 成功标志 | 失败排查 |
| --- | --- | --- | --- | --- |
| `ssh ubuntu@<IP>` | 登录服务器 | Windows PowerShell 直接执行 | 出现 `ubuntu@dnf-...:~$` | 端口/防火墙；密码错误；`ping` 不通 |
| `scp 文件 ubuntu@<IP>:/路径` | 上传文件 | 本机执行 | 进度 100% | 路径不存在；权限；大文件用 `rsync -P` |
| `docker build -t servers5a3-local:dev -f deploy/docker/Dockerfile .` | 构建服务端 | 仓库根目录 | `naming to ... done` | GOPROXY 未打；网络；磁盘满 |
| `sh deploy/docker/manage.sh prepare --pvf ... --channel-info ... --host-ip ...` | 生成运行配置 | 仓库根目录 | `Prepared 120 real channels` | PVF 路径；频道表；host-ip 校验 |
| `sh deploy/docker/manage.sh up` | 启动游戏服务 | 仓库根目录 | 两容器 healthy | 端口占用；镜像缺失；数据库卷 |
| `sh deploy/docker/manage.sh status` / `logs` / `down` | 状态/日志/停止 | 仓库根目录 | 对应输出 | — |
| `curl -s http://127.0.0.1:17002/api/status` | 账号 API 健康 | 任意目录 | `{"ok":true,...}` | 容器未起；DSN 错 |
| `ss -lnt \| grep -c '<IP>:10'` | 频道端口数 | 任意目录 | 120 | 防火墙；prepare 未执行 |
| `docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml build` | 构建网关 | PurpleMagic 根目录 | `purplemagic:local` | GOPROXY/Debian 源；磁盘 |
| `python3 deploy/selfhost/prepare.py --settings ... --output ...` | 生成网关运行目录 | PurpleMagic 根目录 | `Private configuration prepared` | 证书/域名校验；输出目录已存在 |
| `docker compose ... --profile setup run --rm index-items` | 建物品索引 | PurpleMagic 根目录 | `item index ready` | PVF 路径；磁盘；时间 |
| `docker compose ... up -d gateway gm edge` | 启动网关 | PurpleMagic 根目录 | 三容器 running | 索引缺失；证书；端口 |
| `curl -s --cacert <ca> https://<地址>:8443/api/status` | 玩家网关健康 | 任意目录 | `{"ok":true,...}` | 证书指纹；8443；DNS |
| `bash ops-verify.sh` | 一键自检 | `/srv/dnf/ops` | `VERIFY_OK` | 按 FAIL 项排查 |
| `bash ops-backup.sh` | 备份 | `/srv/dnf/ops` | 输出三份 SHA256 | 数据库容器未起；磁盘 |
| `POST /admin/api/bundle/<版本>` | 发布登录器更新 | 任意（带 Token） | 返回 version/url/sha256 | Token；版本未递增；包结构 |
| `hub-migrate-profile.py` | 迁移 EXE/PVF 发布状态 | `/srv/dnf/toolkit/tools`（脚本也查 `/srv/dnf/tools`） | sequence+1、哈希变化 | gateway 未停；profile 不匹配 |
| `build-launcher.bat <flutter> <dotnet> <输出>` | 构建登录器 | Windows 源码根目录 | 四个产物 | Flutter/.NET/VS/素材/profile |
| `deploy-windows.bat` | Windows 交互菜单 | Windows 工具包目录 | 菜单正常 | PowerShell 执行策略（脚本已带 Bypass） |

## 14. 配置与修改

### 14.1 `ServerS5A3/runtime/docker/instance.json`

| 字段 | 含义 | 什么时候改 |
| --- | --- | --- |
| `host_ip` | 端口绑定 + 默认通告地址 | 换服务器 IP |
| `advertise_ip` | 通告给玩家的地址（NAT 时填公网 IP） | 云主机私网绑定 + 公网访问 |
| `public_bootstrap` | 7001 是否绑到局域网地址 | 必须 `true`，否则 Windows 连不上 |
| `joust_event_enabled` | 2365 赛马 | 保持 `false` |
| `dungeon_tournament` | 普通/魂大会赛程 | `"vendor"` |
| `channel_advertise_server` | 频道目录里的区服号 | 必须等于登录器 `ChannelServerId`（默认 1） |
| `channel_directory_owner_range` | 是否过滤 >255 频道 | `"u8"` |
| `restart` | 容器重启策略 | `"unless-stopped"` |
| `player_admin_secret` | GM 管理 API Token | 生成后不要改（改了要同步 settings） |
| `player_proxy_secret` | 网关代理密钥 | 与 PurpleMagic `game.proxySecret` 一致 |

修改示例（把通告地址改成公网 IP）：

```json
{
  "host_ip": "10.0.0.17",
  "advertise_ip": "1.15.60.33"
}
```

改完必须重新 `prepare` + `up`，否则只改了文件、容器里仍是旧环境变量。

### 14.2 `PurpleMagic/runtime/launcher-input/server.json`

```json
{
  "ApiUrl": "https://192.168.200.130:8443",
  "GameHost": "192.168.200.130",
  "BootstrapPort": 7001,
  "ChannelServerId": 1
}
```

- `ApiUrl`：玩家 HTTPS 网关，必须 8443；IP 或域名；
- `GameHost`：玩家直连的游戏地址（IP）；
- `BootstrapPort`：频道引导端口（7001）；
- `ChannelServerId`：与 `channel_advertise_server` 一致。

改完要重新生成 `profile.json`（`prepare_launcher_profile.py`），再重编登录器。

### 14.3 `PurpleMagic/runtime/selfhost-settings.json`

| 字段 | 说明 |
| --- | --- |
| `gmOrigin` | GM 网页地址（https，443，IP 或域名） |
| `approvedProfile` / `signingPrivateKey` / `pvfFile` | 对应文件路径 |
| `playerCertificate` / `playerCA` / `webCertificate` | 证书（自签或正式） |
| `database.registrationDsn` / `repositoryDsn` | `dnf:<密码>@tcp(10.253.90.3:3306)/dnf_local?...` |
| `game.upstream` / `adminUrl` / `adminToken` | 游戏账号 API / 管理 API / Token |

改完用新的 `--output` 重跑 `prepare.py`（或归档旧目录后重跑），再重建容器。

### 14.4 `profile.json`

**不要手改**。它由 `prepare_launcher_profile.py` 从 server.json + 客户端 EXE/PVF + 证书生成，包含证书指纹与文件哈希；手改会导致登录器校验失败。

### 14.5 修改后的动作对照

| 改了什么 | 必须做什么 |
| --- | --- |
| instance.json（IP/策略） | `manage.sh prepare` → `manage.sh up` |
| server.json（地址） | 重新生成 profile → Windows 重编登录器 |
| 证书 | 重新生成 profile → 重编登录器 |
| PVF | 服务端 prepare/up；PurpleMagic 新 profile + 迁移发布状态 + 重建索引；客户端换 PVF |
| settings.json | 新目录 prepare.py → 重建 gateway/gm |
| 活动开关 | 管理接口保存或改 env → 重启游戏服务 |

## 15. 连接与传输

### 15.1 SSH 连接

```powershell
ssh ubuntu@192.168.200.130
# 首次会提示确认指纹，输入 yes
# 密码：安装时设置的（本机示例 dnf123456）
```

- 端口不是 22：`ssh -p 2222 ubuntu@<IP>`；
- 密钥登录：`ssh -i D:\path\key ubuntu@<IP>`；
- 连不上：先在服务器控制台 `ip a` 确认地址，再确认防火墙/安全组放行 22。

### 15.2 上传文件

```powershell
# 单个文件
scp .\Script.pvf ubuntu@192.168.200.130:/srv/dnf/assets/
# 整个目录
scp -r .\ServerS5A3 ubuntu@192.168.200.130:/srv/dnf/
# 大文件断点续传（服务器需装 rsync）
rsync -P .\Script.pvf ubuntu@192.168.200.130:/srv/dnf/assets/
```

### 15.3 VMware 控制台（网络不通时）

- VMware 里选中虚拟机 → 打开控制台，用 `ubuntu` 登录；
- 查地址：`ip -4 addr show`；
- 改静态 IP：编辑 `/etc/netplan/01-dnf-static.yaml` 后 `sudo netplan apply`；
- 控制台里粘贴命令：VMware 菜单 `虚拟机 → 发送键 → 粘贴`，或用 SSH。

### 15.4 长时间命令

```sh
# 后台跑并保留日志
nohup setsid sh deploy/docker/manage.sh build > /tmp/build.log 2>&1 < /dev/null &
tail -f /tmp/build.log

# 或使用 tmux（避免 SSH 断线中断）
sudo apt-get install -y tmux
tmux new -s deploy
# 里面执行命令，Ctrl+B 然后 D 退出；tmux a -t deploy 回来
```

### 15.5 从 Windows 执行单条远程命令

```powershell
ssh ubuntu@192.168.200.130 "bash /srv/dnf/ops/ops-verify.sh"
ssh ubuntu@192.168.200.130 "docker ps --format '{{.Names}} {{.Status}}'"
```
