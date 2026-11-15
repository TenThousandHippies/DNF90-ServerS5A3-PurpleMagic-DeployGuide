#!/bin/bash
# =============================================================================
# DNF90 (ServerS5A3) + PurpleMagic 一键部署脚本 — Linux 侧
#
# 在全新 Ubuntu 24.04 上以普通用户（有 sudo）执行：
#   bash deploy-oneclick.sh --host-ip 192.168.200.130 \
#        --pvf /srv/dnf/assets/Script.pvf \
#        --client-dir /srv/dnf/client          # 含 DNF.exe 与 Script.pvf
#
# 默认无域名（IP 直连）：不传 --players-host/--gm-host 即用 --host-ip。
# 需要域名时再传 --players-host players.example.com --gm-host gm.example.com。
#
# 可选：--server-src /path/ServerS5A3   --pm-src /path/PurpleMagic
#       --channel-info /path/channel_info.etc
#       --players-host players.example.com --gm-host gm.example.com
#       --resume            # 复用已有 runtime 配置（不重新 prepare）
# =============================================================================
set -euo pipefail

HOST_IP=""
PVF=""
CLIENT_DIR=""
SERVER_SRC=""
PM_SRC=""
CHANNEL_INFO=""
PLAYERS_HOST=""
GM_HOST=""
RESUME=0
WORK=/srv/dnf
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOG=$WORK/logs/deploy-$(date +%Y%m%d-%H%M%S).log

say()  { echo -e "\n== $* =="; }
fail() { echo "ERROR: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host-ip) HOST_IP=$2; shift 2 ;;
    --pvf) PVF=$2; shift 2 ;;
    --client-dir) CLIENT_DIR=$2; shift 2 ;;
    --server-src) SERVER_SRC=$2; shift 2 ;;
    --pm-src) PM_SRC=$2; shift 2 ;;
    --channel-info) CHANNEL_INFO=$2; shift 2 ;;
    --players-host) PLAYERS_HOST=$2; shift 2 ;;
    --gm-host) GM_HOST=$2; shift 2 ;;
    --resume) RESUME=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) fail "未知参数 $1" ;;
  esac
done
[ -n "$HOST_IP" ] || fail "缺少 --host-ip"
[ -n "$PVF" ] || fail "缺少 --pvf"
[ -f "$PVF" ] || fail "PVF 不存在：$PVF"
[ -n "$PLAYERS_HOST" ] || PLAYERS_HOST="$HOST_IP"
[ -n "$GM_HOST" ] || GM_HOST="$HOST_IP"

sudo -n true 2>/dev/null || fail "需要免密 sudo（NOPASSWD）；请先配置 sudoers 或手动执行一次 sudo"
sudo mkdir -p "$WORK"/logs "$WORK"/assets
sudo chown -R "$(id -u):$(id -g)" "$WORK"
exec > >(tee -a "$LOG") 2>&1
say "日志：$LOG"

# ---------------------------------------------------------------- 1. 基础环境
say "1/10 基础工具与 Docker"
if ! command -v docker >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg git jq unzip openssl python3 >/dev/null
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /tmp/docker.gpg \
    || curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  REPO=https://mirrors.aliyun.com/docker-ce/linux/ubuntu
  curl -fsS -o /dev/null "$REPO/dists/noble/Release" || REPO=https://download.docker.com/linux/ubuntu
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] $REPO noble stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
  sudo usermod -aG docker "$USER" || true
fi
sudo mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run", "https://dockerproxy.net"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
fi
sudo systemctl enable --now docker >/dev/null 2>&1
sudo systemctl restart docker
DOCKER="sg docker -c"
$DOCKER "docker info >/dev/null" || fail "当前用户无法访问 Docker"

# ---------------------------------------------------------------- 2. 源码
say "2/10 获取源码"
if [ -n "$SERVER_SRC" ]; then
  rsync -a --delete --exclude .git "$SERVER_SRC"/ "$WORK/ServerS5A3"/
else
  [ -d "$WORK/ServerS5A3/.git" ] || git clone https://github.com/Cec1c/ServerS5A3.git "$WORK/ServerS5A3"
fi
if [ -n "$PM_SRC" ]; then
  rsync -a --delete --exclude .git "$PM_SRC"/ "$WORK/PurpleMagic"/
else
  [ -d "$WORK/PurpleMagic/.git" ] || git clone https://github.com/Cec1c/PurpleMagic.git "$WORK/PurpleMagic"
fi
cd "$WORK/ServerS5A3"
git rev-parse HEAD 2>/dev/null || echo "(无 git 元数据)"

# ---------------------------------------------------------------- 3. 本地补丁
say "3/10 构建补丁"
PATCHER="$SCRIPT_DIR/patches/apply-local-patches.py"
[ -f "$PATCHER" ] || fail "缺少补丁脚本：$PATCHER"
python3 "$PATCHER" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" \
  || fail "补丁应用失败：上游可能改动了相关文件，请对照 patches/README.md 手工处理"

# ---------------------------------------------------------------- 4. 构建服务端
say "4/10 构建服务端镜像（首次 5-15 分钟）"
cd "$WORK/ServerS5A3"
$DOCKER "docker build -t servers5a3-local:dev -f deploy/docker/Dockerfile ."

# ---------------------------------------------------------------- 5. prepare
say "5/10 生成运行配置（显式外部频道表）"
if [ "$(readlink -f "$PVF")" != "$(readlink -f "$WORK/assets/Script.pvf" 2>/dev/null || echo -)" ]; then
  cp -f "$PVF" "$WORK/assets/Script.pvf"
fi
if [ -z "$CHANNEL_INFO" ]; then
  CHANNEL_INFO="$WORK/ServerS5A3/go-server/internal/services/dnfbridge/testdata/channel_info.etc"
fi
[ -f "$CHANNEL_INFO" ] || fail "频道表不存在：$CHANNEL_INFO"
INSTANCE="$WORK/ServerS5A3/runtime/docker/instance.json"
if [ -f "$INSTANCE" ] && [ "$RESUME" = "0" ]; then
  fail "已存在运行配置 $INSTANCE。复用请加 --resume；全新部署请先备份并移走 runtime/docker"
fi
if [ "$RESUME" = "0" ]; then
  $DOCKER "cd $WORK/ServerS5A3 && sh deploy/docker/manage.sh prepare --pvf $WORK/assets/Script.pvf --channel-info $CHANNEL_INFO --host-ip $HOST_IP"
else
  echo "resume：复用 $INSTANCE"
fi
[ -f "$INSTANCE" ] || fail "prepare 未生成 instance.json"

say "5b/10 写入部署策略（赛马关闭 / 大会 vendor / 区服 1 / 开机自启）"
python3 - "$INSTANCE" <<'PY'
import json, secrets, sys
from pathlib import Path
p = Path(sys.argv[1]); c = json.loads(p.read_text())
if not c.get("player_admin_secret"):
    c["player_admin_secret"] = secrets.token_hex(32)
c.update({
    "joust_event_enabled": False,
    "dungeon_tournament": "vendor",
    "channel_directory_owner_range": "u8",
    "channel_advertise_server": 1,
    "public_bootstrap": True,
    "restart": "unless-stopped",
})
p.write_text(json.dumps(c, indent=2) + "\n")
print({k: c[k] for k in ("joust_event_enabled","dungeon_tournament","channel_advertise_server","public_bootstrap","restart")})
PY

say "5c/10 启动游戏服务"
cd "$WORK/ServerS5A3"
$DOCKER "cd $WORK/ServerS5A3 && sh deploy/docker/manage.sh up"
for i in $(seq 1 60); do
  sleep 5
  curl -s --max-time 4 http://127.0.0.1:17002/api/status | grep -q '"ok":true' && break
done
curl -s http://127.0.0.1:17002/api/status || fail "账号 API 未就绪"

# ---------------------------------------------------------------- 6. 登录器输入
say "6/10 生成 PurpleMagic 输入"
cd "$WORK/PurpleMagic"
umask 077
mkdir -p runtime/launcher-input runtime/client-input
cp -f "$PVF" runtime/client-input/Script.pvf
if [ -n "$CLIENT_DIR" ] && [ -f "$CLIENT_DIR/DNF.exe" ]; then
  cp -f "$CLIENT_DIR/DNF.exe" runtime/client-input/DNF.exe
fi
[ -f runtime/client-input/DNF.exe ] || fail "缺少 DNF.exe：请用 --client-dir 指定客户端目录"

cat > runtime/launcher-input/server.json <<JSON
{
  "ApiUrl": "https://$PLAYERS_HOST:8443",
  "GameHost": "$HOST_IP",
  "BootstrapPort": 7001,
  "ChannelServerId": 1,
  "MinimumLauncherVersion": "0.2.20",
  "DefaultClientDirectory": ""
}
JSON

if [ -f runtime/launcher-input/profile.json ]; then
  echo "已存在 profile.json，跳过证书/签名/profile 生成（复用）"
else
case "$PLAYERS_HOST" in
  *[!0-9.]*) SAN="DNS:$PLAYERS_HOST" ;;
  *) SAN="IP:$PLAYERS_HOST" ;;
esac
case "$GM_HOST" in
  *[!0-9.]*) case "$SAN" in *"DNS:$GM_HOST"*) : ;; *) SAN="$SAN,DNS:$GM_HOST" ;; esac ;;
  *) [ "$GM_HOST" = "$PLAYERS_HOST" ] || SAN="$SAN,IP:$GM_HOST" ;;
esac
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
  -keyout runtime/launcher-input/local-tls-key.pem -out runtime/launcher-input/local-tls.pem \
  -subj "/CN=$PLAYERS_HOST" \
  -addext "subjectAltName=$SAN" \
  -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out runtime/launcher-input/signing-key.pem 2>/dev/null
openssl pkey -in runtime/launcher-input/signing-key.pem -pubout -out runtime/launcher-input/update-public.pem 2>/dev/null
python3 scripts/prepare_launcher_profile.py \
  --connection runtime/launcher-input/server.json \
  --client runtime/client-input \
  --certificate runtime/launcher-input/local-tls.pem \
  --public-key runtime/launcher-input/update-public.pem \
  --output runtime/launcher-input/profile.json
fi

python3 - "$WORK" "$GM_HOST" <<'PY'
import json, sys
from pathlib import Path
work = Path(sys.argv[1]); gm = sys.argv[2]
inst = json.loads((work/'ServerS5A3/runtime/docker/instance.json').read_text())
root = work/'PurpleMagic'
launcher = root/'runtime/launcher-input'
dsn = f"dnf:{inst['database_password']}@tcp(10.253.90.3:3306)/dnf_local?parseTime=true&charset=utf8mb4"
s = {
  "gmOrigin": f"https://{gm}",
  "approvedProfile": str(launcher/'profile.json'),
  "signingPrivateKey": str(launcher/'signing-key.pem'),
  "pvfFile": str(root/'runtime/client-input/Script.pvf'),
  "playerCertificate": str(launcher/'local-tls.pem'),
  "playerPrivateKey": str(launcher/'local-tls-key.pem'),
  "playerCA": str(launcher/'local-tls.pem'),
  "webCertificate": str(launcher/'local-tls.pem'),
  "webPrivateKey": str(launcher/'local-tls-key.pem'),
  "database": {"registrationDsn": dsn, "repositoryDsn": dsn,
               "accountTable": "dnf90_web_accounts", "databases": ["dnf_local"], "tablePrefix": "dnf"},
  "game": {"upstream": "http://127.0.0.1:17002",
           "proxySecret": inst["player_proxy_secret"],
           "adminUrl": "http://127.0.0.1:17002/api/game/admin",
           "adminToken": inst["player_admin_secret"]},
}
p = root/'runtime/selfhost-settings.json'
p.write_text(json.dumps(s, ensure_ascii=False, indent=2) + "\n"); p.chmod(0o600)
print('settings written')
PY

# ---------------------------------------------------------------- 7. 网关构建
say "7/10 构建 PurpleMagic 镜像"
cd "$WORK/PurpleMagic"
[ -d runtime/selfhost ] || python3 deploy/selfhost/prepare.py --settings runtime/selfhost-settings.json --output runtime/selfhost
$DOCKER "cd $WORK/PurpleMagic && docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml build"

# ---------------------------------------------------------------- 8. 索引与表
say "8/10 PVF 索引与管理表（PVF 大，约 10-25 分钟）"
C="docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml"
for step in index-pvf index-items index-quests index-professions schema; do
  echo "-- $step"
  $DOCKER "cd $WORK/PurpleMagic && $C --profile setup run --rm $step" || fail "$step 失败"
done

# ---------------------------------------------------------------- 9. 启动网关
say "9/10 启动 gateway / gm / edge"
$DOCKER "cd $WORK/PurpleMagic && $C up -d gateway gm edge"
sleep 8
$DOCKER "cd $WORK/PurpleMagic && $C ps"

say "9b/10 安装运维脚本与每日备份"
mkdir -p "$WORK/ops"
for f in "$SCRIPT_DIR"/ops-*.sh; do
  [ -f "$f" ] && cp -f "$f" "$WORK/ops/"
done
chmod +x "$WORK"/ops/*.sh 2>/dev/null || true
if [ -f "$SCRIPT_DIR/dnf-backup.service" ] && [ -f "$SCRIPT_DIR/dnf-backup.timer" ]; then
  sudo cp -f "$SCRIPT_DIR/dnf-backup.service" "$SCRIPT_DIR/dnf-backup.timer" /etc/systemd/system/
  sudo systemctl daemon-reload
  sudo systemctl enable --now dnf-backup.timer
  echo "已启用每日 04:10 自动备份（dnf-backup.timer）"
fi
ls -1 "$WORK/ops"

# ---------------------------------------------------------------- 10. 验收
say "10/10 验收"
cd "$WORK/PurpleMagic"
echo "本机 hosts 需要：$HOST_IP $PLAYERS_HOST $GM_HOST"
case "$PLAYERS_HOST" in
  *[!0-9.]*)
    # 域名模式：cloud-init 每次开机重写 /etc/hosts，必须同时写模板才能持久
    grep -q "$PLAYERS_HOST" /etc/hosts || echo "$HOST_IP $PLAYERS_HOST $GM_HOST" | sudo tee -a /etc/hosts >/dev/null
    HOSTS_TMPL=/etc/cloud/templates/hosts.debian.tmpl
    if [ -f "$HOSTS_TMPL" ] && ! grep -q "$PLAYERS_HOST" "$HOSTS_TMPL"; then
      echo "$HOST_IP $PLAYERS_HOST $GM_HOST" | sudo tee -a "$HOSTS_TMPL" >/dev/null
      echo "已写入 cloud-init hosts 模板（重启后不丢失）"
    fi
    ;;
  *)
    echo "IP 模式：无需 hosts（玩家直接访问 $HOST_IP）"
    ;;
esac
curl -s --max-time 8 --cacert runtime/selfhost/tls-player/ca.pem https://$PLAYERS_HOST:8443/api/status; echo
curl -s --max-time 8 --cacert runtime/selfhost/tls-player/ca.pem -o /dev/null \
  -w "bootstrap=%{http_code}\n" https://$PLAYERS_HOST:8443/launcher/v2/bootstrap.json
echo "频道端口数：$(ss -lnt | grep -c "$HOST_IP:10")"
echo "管理员 Token：$(cat runtime/selfhost/admin-token.txt)"
echo
if [ -x "$WORK/ops/ops-verify.sh" ]; then
  bash "$WORK/ops/ops-verify.sh" | tail -8
fi
echo "部署完成。登录器构建在 Windows 侧执行（见指南第 5 节与 6.2 节）。"
echo "常用：/srv/dnf/ops/ops-status.sh / ops-logs.sh / ops-backup.sh / ops-verify.sh"
