# DNF90（ServerS5A3 + PurpleMagic）部署指南

> 适用版本：ServerS5A3 `master`（本文验证于 `44e3482`，2026-11-14）、PurpleMagic `main`（验证于 `216d5888`）。
> 本文所有路径、命令都在 192.168.200.130 这台 Ubuntu 24.04 虚拟机上实际执行过；换机器时只需替换 IP。
> **默认部署模式：无域名（纯 IP）**——`ApiUrl=https://<IP>:8443`、GM `https://<IP>`，证书带 IP SAN，玩家不需要改 hosts。需要域名时见 7.6。

## 交付物清单

| 文件 | 用途 |
| --- | --- |
| `DEPLOY_GUIDE.md` | 本指南 |
| `deploy-oneclick.sh` | Linux 侧一键部署（服务端 + 网关 + GM + 配置 + 索引 + 自检） |
| `build-launcher.bat` | Windows 侧构建脚本（Flutter + NativeAOT + 便携 EXE） |
| `deploy-windows.bat` / `.ps1` | Windows 侧交互菜单（环境/源码/补丁/地址/构建/发布） |
| `patches/windows/` | Windows 侧必要补丁与功能补丁目录约定 |
| `tools/hub-migrate-profile.py` | PVF 变更时迁移 Hub 发布状态（免重编登录器） |
| `ops-start.sh` / `ops-stop.sh` / `ops-status.sh` / `ops-logs.sh` / `ops-backup.sh` / `ops-verify.sh` | 日常运维与自检 |
| `evidence/` | 一键部署实测日志与自检输出 |

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
# 必须是 e04a80759359d6fd5e17c78831a554e3a7faa050896a9ad8975d98515ec87aeb（120 条）
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
# 120 external:channel.override.etc e04a8075... 120
```

### 3.4 改 `runtime/docker/instance.json`

只改这些字段，其余保留：

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
python3 /srv/dnf/tools/hub-migrate-profile.py --selfhost runtime/selfhost \
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
2026-11-14 在本机（Flutter 3.47.9 / .NET 8.0.427 / VS Build Tools 17.14）实测通过，产物 23 MB，日志见 `evidence/build-launcher-20261114.log`。

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
2. 三处版本号一起 +1：`LauncherEngine.cs` 的 `VersionText`、`Launcher.Host.csproj` 的 `<Version>`、`launcher/Flutter/pubspec.yaml`；
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

### 6.1 把工具包放到服务器

```sh
# 在你自己的电脑上（Windows PowerShell 也可以）
scp DNF90-部署工具包.zip ubuntu@192.168.200.130:/srv/dnf/

# 登录服务器
ssh ubuntu@192.168.200.130

# 解压并运行
cd /srv/dnf
unzip -o DNF90-部署工具包.zip -d toolkit
cd toolkit
chmod +x *.sh
bash deploy-oneclick.sh
```

运行后会显示功能菜单。所有输出同时写入 `/srv/dnf/logs/deploy-<时间>.log`，选择保存在 `/srv/dnf/deploy.conf`，下次运行会记住上次的 IP/模式/源码。

### 6.2 菜单一览

| 编号 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 安装/检查 Docker 与运行环境 | 检测 docker/git/python3/openssl/curl；缺什么装什么；Docker 用阿里云源，失败回退官方源 |
| 2 | 配置镜像加速 | 写 `/etc/docker/daemon.json`（registry-mirrors + 日志轮转）；可选 apt 换清华源 |
| 3 | 选择源码 | 本地源码（给上传路径并循环检测）或 Git（clone/更新，失败重试） |
| 4 | 选择部署方式与地址 | IP 或域名；显示本机网卡/IP/公网出口；校验输入；NAT 场景自动拆分绑定 IP 与通告 IP |
| 5 | 打必要补丁 | 调 `patches/apply-local-patches.py`，11 项，源码升级后必须重打 |
| 6 | 可选功能补丁 | 遍历 `patches/features/<名称>/apply.sh`，逐个询问 |
| 7 | 构建服务端镜像 | `docker build -t servers5a3-local:dev` |
| 8 | prepare 服务端配置 | 显式 120 频道外部 ETC；写关赛马/vendor/区服 1/7001 公开/advertise_ip |
| 9 | 启动游戏服务 | `manage.sh up` 并等待账号 API 就绪 |
| 10 | 生成 PurpleMagic 配置 | server.json、证书（IP 或域名 SAN）、签名、profile（备份旧文件）、settings |
| 11 | 构建 PurpleMagic 镜像 | `docker compose ... build` |
| 12 | 生成 PurpleMagic 运行目录 | 归档旧 `runtime/selfhost`，`prepare.py` 生成新目录 |
| 13 | 建索引与管理表 | `index-pvf/items/quests/professions/schema` |
| 14 | 启动 gateway/gm/edge | 三个容器并打印状态 |
| 15 | 完整一键部署 | 1→14 串联（每一步仍会询问必要输入） |
| 16 | 状态/日志/备份/自检 | 二级菜单：状态、服务端日志、网关日志、立即备份、自检 |
| 0 | 退出 | |

### 6.3 各步骤的输入与成功标志

**1) 安装/检查 Docker**：不需要输入。成功会打印 `Docker 29.x / Compose v5.x`。
如果提示 `需要免密 sudo`，先在服务器上配好 `ubuntu ALL=(ALL) NOPASSWD:ALL`（云镜像默认就是）。

**2) 镜像加速**：两个 y/n。建议都 `y`。成功后 `docker info` 的 `Registry Mirrors` 能看到三个地址。

**3) 选择源码**：
- 选 `1` 本地源码时，脚本会打印上传位置和 `scp` 示例，然后循环检测这四个文件：
  `ServerS5A3/AGENTS.md`、`ServerS5A3/go-server/`、`PurpleMagic/deploy/selfhost/prepare.py`、`PurpleMagic/launcher/`。
  没传完会一直提示，输入 `q` 取消。
- 选 `2` Git 时，自动 `git clone`（失败重试 3 次）或 `git pull --ff-only`。
成功标志：`源码就绪：/srv/dnf/ServerS5A3 / /srv/dnf/PurpleMagic`。

**4) 选择部署方式与地址**：
- 脚本先打印本机所有 IPv4、默认出口地址、探测到的公网出口地址；
- IP 模式：输入玩家能访问的 IP。若该 IP 不在本机网卡上（云公网 IP/NAT），会再问一次"本机私网 IP"，用于端口绑定，公网 IP 只做通告；
- 域名模式：输入主域名（如 `example.com`），自动生成 `players.example.com` / `gm.example.com`，再输入服务器 IP 用于玩家直连。需要提前做两条 A 记录，证书也要覆盖这两个域名。
- 校验不通过会重新询问，示例格式都会打印。
成功标志：`部署方式：ip  BIND_IP=... 公网/玩家地址=...`（域名模式还会打印 players/gm）。

**5) 必要补丁**：无输入。成功标志 `11/11 patches present`。任何一项失败都会中止并提示看 `patches/README.md`。

**6) 可选功能补丁**：目录为空时直接提示"当前没有可选功能补丁"。有补丁时逐个 y/n。

**7) 构建服务端镜像**：无输入。首次 5-15 分钟；成功标志 `servers5a3-local:dev 构建完成`。

**8) prepare**：无输入。成功标志 `prepare 完成，频道数见 manifest`，同时打印 instance.json 的关键字段。
公网 IP 不在网卡上时会自动加 `DNF_ALLOW_PUBLIC_HOST=1`。

**9) 启动游戏服务**：无输入。等待最多 5 分钟，成功标志账号 API 返回 `{"ok":true,...}`。

**10) PurpleMagic 配置**：
- 会检查 `runtime/client-input/DNF.exe`，缺失会提示先从客户端复制；
- 证书不存在会自动生成；存在会问是否重签（换 IP/域名时必须 `y`）；
- profile 旧文件会重命名备份后再生成。
成功标志 `profile 与 settings 已生成`。

**11) 构建网关镜像**：需要先有 `runtime/selfhost/compose.env`（菜单 12 生成）。顺序是 10 → 12 → 11。

**12) 生成运行目录**：旧 `runtime/selfhost` 自动归档为 `runtime/selfhost-bak-<时间>`，新目录重新生成。

**13) 建索引**：无输入，`index-items` 最慢（4 vCPU 约 12-25 分钟）。中断后重跑会复用已完成的索引。

**14) 启动网关**：无输入，成功后打印三个容器状态。

**15) 完整一键**：按 1→14 串联；第 2 步会问两个 y/n，第 3/4 步需要选择源码和地址，其余自动。

**16) 状态/日志/备份/自检**：再输入 1-5 选择子功能。

### 6.4 典型会话（IP 模式）

```text
$ bash deploy-oneclick.sh
------------------------------------------------------------
DNF90 交互式部署  —  2026-11-15 13:00:00
------------------------------------------------------------
  1) 安装/检查 Docker 与运行环境
  ...
 15) 完整一键部署（1→14 串联）
 16) 状态/日志/备份/自检
  0) 退出
------------------------------------------------------------
请输入功能编号 [15]: 15
...
请输入服务端 IP（玩家可访问的地址） [192.168.200.130]:
...
[OK] 部署方式：ip  BIND_IP=192.168.200.130  公网/玩家地址=192.168.200.130
...
11/11 patches present
...
servers5a3-local:dev 构建完成
...
{"ok":true,"message":"dnf90 account api ready"}
...
部署完成
管理员 Token：xxxxxxxx
```

### 6.5 中断、续跑与幂等

- 任何一步失败都可以回到菜单重跑该步，不需要从头开始；
- 第 8 步重复执行会重新生成配置（PVF 摘要一致时不会重复拷贝）；
- 第 10 步重复执行会备份旧 profile 再生成；证书会询问是否重签；
- 第 12 步重复执行会归档旧目录（因此每次换 PVF/证书后重跑是安全的，旧数据留在 `selfhost-bak-*`）；
- 第 13 步会复用已生成的索引文件，只有 PVF 变了才会重建。

### 6.6 Windows 侧交互脚本

```bat
deploy-windows.bat
```

菜单：

| 编号 | 功能 | 说明 |
| --- | --- | --- |
| 1 | 环境检查 | Flutter / .NET 8 / VS C++ / Git / Python，版本不对会提示 |
| 2 | 选择源码目录 | 校验 `deploy\windows\build_flutter_launcher.py` 与 `runtime\launcher-input\profile.json` |
| 3 | 打必要补丁 | `patches\windows\required\<名称>\apply.ps1`；当前没有必须补丁时会明确提示 |
| 4 | 可选功能补丁 | `patches\windows\features\<名称>\apply.ps1`，逐个 y/n |
| 5 | 输入服务器地址 | IP 或域名 + 校验 profile 的 ApiUrl/GameHost 是否与输入一致 |
| 6 | 构建登录器 | 调 `build-launcher.bat`，输出目录可自定义 |
| 7 | 发布自更新包 | 把 `-app-update.zip` POST 到 Hub，需要管理员 Token 文件 |

选择会保存到 `windows-build.json`，下次运行自动带出。构建日志在控制台；产物在输出目录（`.exe`、`.zip`、`-app-update.zip`）。

### 6.7 边界

- 脚本不做数据库迁移；迁移见 7.5。
- 索引耗时与磁盘占用见 1.2。
- NAT 云主机需要安全组/端口映射；脚本只负责绑定与通告地址。
- 域名模式仍需要证书覆盖域名；IP 模式证书用 `IP:<地址>` SAN。

---

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
| `hub-migrate-profile.py` | 迁移 PVF 发布状态 | `/srv/dnf/tools` | sequence+1、哈希变化 | gateway 未停；profile 不匹配 |
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
