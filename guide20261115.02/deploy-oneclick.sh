#!/bin/bash
# =============================================================================
# DNF90 (ServerS5A3 + PurpleMagic) 交互式一键部署 — Linux 侧
#
#   bash deploy-oneclick.sh            # 显示功能菜单
#   bash deploy-oneclick.sh --self-test  # 只做环境/IP/校验自测，不改任何文件
#
# 菜单功能：
#   1 安装/检查 Docker 与运行环境      5 生成 PurpleMagic 配置（证书/profile/settings）
#   2 配置镜像加速                     6 构建 PurpleMagic 镜像
#   3 选择源码（本地/Git）             7 建索引与管理表
#   4 部署服务端（构建/prepare/启动）  8 启动 gateway/gm/edge 并自检
#   9 完整一键部署（3→8 串联）        10 状态/日志/备份/自检
#   0 退出
# =============================================================================
set -uo pipefail

WORK=/srv/dnf
STATE=$WORK/deploy.conf
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOG_DIR=$WORK/logs
LOG=$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log
CA=$WORK/PurpleMagic/runtime/selfhost/tls-player/ca.pem

mkdir -p "$LOG_DIR" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

# ---------------------------------------------------------------- 基础函数
c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()    { c_err "错误：$*"; exit 1; }
hr()     { printf '%s\n' "------------------------------------------------------------"; }

ask() { # ask <提示> <默认值>
  local prompt=$1 def=${2:-} v
  if [ -n "$def" ]; then read -rp "$prompt [$def]: " v; v=${v:-$def}; else read -rp "$prompt: " v; fi
  printf '%s' "$v"
}

ask_yes() { # ask_yes <提示> [默认y/n]
  local prompt=$1 def=${2:-n} v
  read -rp "$prompt [$([ "$def" = y ] && echo Y/n || echo y/N)]: " v
  v=${v:-$def}
  case "$v" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

valid_ipv4() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a o <<< "$ip"
  for n in "${o[@]}"; do [ "$n" -ge 0 ] 2>/dev/null && [ "$n" -le 255 ] || return 1; done
  [ "$ip" != "0.0.0.0" ] && [ "${ip%%.*}" != "127" ]
}

valid_domain() {
  [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

load_state() { [ -f "$STATE" ] && . "$STATE" || true; }
save_state() {
  {
    echo "DEPLOY_MODE=${DEPLOY_MODE:-}"
    echo "BIND_IP=${BIND_IP:-}"
    echo "PUBLIC_IP=${PUBLIC_IP:-}"
    echo "PLAYERS_HOST=${PLAYERS_HOST:-}"
    echo "GM_HOST=${GM_HOST:-}"
    echo "SOURCE_KIND=${SOURCE_KIND:-}"
    echo "SERVER_SRC=${SERVER_SRC:-}"
    echo "PM_SRC=${PM_SRC:-}"
    echo "FEATURES=${FEATURES:-}"
  } > "$STATE"
  chmod 600 "$STATE"
}

# ---------------------------------------------------------------- 环境探测
detect_net() {
  echo "本机网卡 IPv4："
  ip -4 -o addr show scope global 2>/dev/null | awk '{printf "  %-10s %s\n", $2, $4}'
  DEFAULT_IF=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  DEFAULT_IP=""
  [ -n "${DEFAULT_IF:-}" ] && DEFAULT_IP=$(ip -4 addr show dev "$DEFAULT_IF" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  [ -n "$DEFAULT_IP" ] && echo "默认出口地址：$DEFAULT_IP"
  PUBLIC_EGRESS=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || curl -s --max-time 4 https://ifconfig.me 2>/dev/null || true)
  [ -n "$PUBLIC_EGRESS" ] && echo "公网出口地址：$PUBLIC_EGRESS（云服务器/公网部署请填它）"
  [ -z "$PUBLIC_EGRESS" ] && echo "未能探测公网出口（无外网或超时），请手动确认公网 IP"
}

is_local_ip() { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"; }
is_rfc1918() {
  case "$1" in 10.*|192.168.*) return 0;; 172.*) n=${1#172.}; n=${n%%.*}; [ "$n" -ge 16 ] && [ "$n" -le 31 ] && return 0;; esac
  return 1
}

# ---------------------------------------------------------------- 菜单功能
menu_install() {
  hr; echo "1) 安装/检查 Docker 与运行环境"
  local need=0
  for c in docker git python3 openssl curl; do command -v $c >/dev/null || { c_warn "缺少 $c"; need=1; }; done
  if [ "$need" = 0 ] && docker info >/dev/null 2>&1; then c_ok "Docker 与基础工具已就绪"; return; fi
  sudo -n true 2>/dev/null || die "需要免密 sudo（NOPASSWD）"

  echo "-> 安装基础工具"
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg git jq unzip openssl python3 >/dev/null

  if ! command -v docker >/dev/null; then
    echo "-> 安装 Docker CE（阿里云源，失败自动回退官方源）"
    sudo install -m 0755 -d /etc/apt/keyrings
    local ok=0
    for i in 1 2 3; do
      curl -fsSL --retry 3 https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /tmp/docker.gpg && ok=1 && break
      curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg && ok=1 && break
      sleep 3
    done
    [ "$ok" = 1 ] || die "Docker GPG 下载失败，请检查网络"
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg /tmp/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    local repo=https://mirrors.aliyun.com/docker-ce/linux/ubuntu
    curl -fsS --max-time 10 -o /dev/null "$repo/dists/noble/Release" || repo=https://download.docker.com/linux/ubuntu
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] $repo noble stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    sudo usermod -aG docker "$USER" || true
  fi
  sudo systemctl enable --now docker >/dev/null 2>&1
  sudo systemctl restart docker
  sg docker -c "docker info >/dev/null" 2>/dev/null || die "当前用户无法访问 Docker，请重新登录后重试"
  c_ok "Docker $(docker --version | awk '{print $3}') / Compose $(docker compose version --short 2>/dev/null)"
}

menu_mirrors() {
  hr; echo "2) 配置镜像加速"
  sudo -n true 2>/dev/null || die "需要免密 sudo"
  if ask_yes "写入 Docker 镜像加速 + 日志轮转配置？" y; then
    sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run", "https://dockerproxy.net"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
    sudo systemctl restart docker
    c_ok "已写入 /etc/docker/daemon.json"
  fi
  if ask_yes "把 apt 源换成清华镜像（国内加速）？" n; then
    sudo cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak 2>/dev/null || true
    sudo sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
    sudo apt-get update -qq
    c_ok "apt 源已切换"
  fi
  echo "提示：容器内 Go 模块走 GOPROXY，由补丁写入 Dockerfile（下一步自动处理）。"
}

menu_source() {
  hr; echo "3) 选择源码"
  echo "  1) 本地源码（先上传到服务器）"
  echo "  2) Git 拉取（GitHub）"
  local kind
  kind=$(ask "请选择" "${SOURCE_KIND:-2}")
  case "$kind" in
    1)
      echo "请把两份源码上传到："
      echo "  $WORK/ServerS5A3   （含 go-server/、deploy/、AGENTS.md）"
      echo "  $WORK/PurpleMagic  （含 gateway/、launcher/、deploy/selfhost/）"
      echo "上传示例（在你自己的电脑执行）："
      echo "  scp -r ServerS5A3  ubuntu@<服务器IP>:$WORK/"
      echo "  scp -r PurpleMagic ubuntu@<服务器IP>:$WORK/"
      while true; do
        [ -f "$WORK/ServerS5A3/AGENTS.md" ] && [ -d "$WORK/ServerS5A3/go-server" ] || { c_warn "未检测到 $WORK/ServerS5A3 完整源码"; }
        [ -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ] || { c_warn "未检测到 $WORK/PurpleMagic 完整源码"; }
        if [ -f "$WORK/ServerS5A3/AGENTS.md" ] && [ -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ]; then break; fi
        read -rp "上传完成后按回车重新检测（输入 q 取消）: " ans; [ "$ans" = q ] && return
      done
      SOURCE_KIND=local; SERVER_SRC=$WORK/ServerS5A3; PM_SRC=$WORK/PurpleMagic
      ;;
    2)
      mkdir -p "$WORK"
      if [ ! -d "$WORK/ServerS5A3/.git" ]; then
        echo "-> 克隆 ServerS5A3"
        for i in 1 2 3; do git clone https://github.com/Cec1c/ServerS5A3.git "$WORK/ServerS5A3" && break; sleep 3; done
        [ -d "$WORK/ServerS5A3/.git" ] || die "ServerS5A3 克隆失败（网络？）"
      else
        (cd "$WORK/ServerS5A3" && git pull --ff-only) || c_warn "ServerS5A3 更新失败，继续使用现有源码"
      fi
      if [ ! -d "$WORK/PurpleMagic/.git" ]; then
        echo "-> 克隆 PurpleMagic"
        for i in 1 2 3; do git clone https://github.com/Cec1c/PurpleMagic.git "$WORK/PurpleMagic" && break; sleep 3; done
        [ -d "$WORK/PurpleMagic/.git" ] || die "PurpleMagic 克隆失败（网络？）"
      else
        (cd "$WORK/PurpleMagic" && git pull --ff-only) || c_warn "PurpleMagic 更新失败，继续使用现有源码"
      fi
      SOURCE_KIND=git; SERVER_SRC=$WORK/ServerS5A3; PM_SRC=$WORK/PurpleMagic
      ;;
    *) c_err "无效选择"; return;;
  esac
  echo "ServerS5A3: $(cd "$SERVER_SRC" && git rev-parse --short HEAD 2>/dev/null || echo '本地源码')"
  save_state
  c_ok "源码就绪：$SERVER_SRC / $PM_SRC"
}

menu_address() {
  hr; echo "4) 选择部署方式与地址"
  detect_net
  echo "  1) IP 直连（无域名，推荐）"
  echo "  2) 域名访问"
  local mode
  mode=$(ask "请选择" "${DEPLOY_MODE:-1}")
  case "$mode" in
    1)
      while true; do
        BIND_IP=$(ask "请输入服务端 IP（玩家可访问的地址）" "${BIND_IP:-$DEFAULT_IP}")
        valid_ipv4 "$BIND_IP" && break
        c_err "IP 不合法，示例：192.168.200.130"
      done
      if is_local_ip "$BIND_IP"; then
        PUBLIC_IP=$BIND_IP
      else
        c_warn "该 IP 不在本机网卡上，按云服务器 NAT 处理：私网绑定 + 公网通告"
        while true; do
          NAT_BIND=$(ask "请输入本机私网 IP（用于绑定端口）" "$DEFAULT_IP")
          valid_ipv4 "$NAT_BIND" && break
          c_err "IP 不合法"
        done
        PUBLIC_IP=$BIND_IP; BIND_IP=$NAT_BIND
      fi
      PLAYERS_HOST=$PUBLIC_IP; GM_HOST=$PUBLIC_IP; DEPLOY_MODE=ip
      ;;
    2)
      while true; do
        local base
        base=$(ask "请输入主域名（示例：example.com，将使用 players.example.com / gm.example.com）" "")
        valid_domain "$base" && break
        c_err "域名格式不合法，示例：example.com"
      done
      PLAYERS_HOST="players.$base"; GM_HOST="gm.$base"
      while true; do
        PUBLIC_IP=$(ask "请输入服务器 IP（玩家直连游戏用）" "${PUBLIC_IP:-$DEFAULT_IP}")
        valid_ipv4 "$PUBLIC_IP" && break
        c_err "IP 不合法"
      done
      if is_local_ip "$PUBLIC_IP"; then BIND_IP=$PUBLIC_IP; else BIND_IP=$DEFAULT_IP; c_warn "公网 IP 不在网卡上，绑定用 $BIND_IP"; fi
      DEPLOY_MODE=domain
      c_warn "域名模式需要：A 记录 players.$base / gm.$base 指向公网 IP；证书需覆盖这两个域名"
      ;;
    *) c_err "无效选择"; return;;
  esac
  save_state
  c_ok "部署方式：$DEPLOY_MODE  BIND_IP=$BIND_IP  公网/玩家地址=$PUBLIC_IP"
  [ "$DEPLOY_MODE" = domain ] && c_ok "players=$PLAYERS_HOST  gm=$GM_HOST"
}

apply_required_patches() {
  hr; echo "5) 打必要补丁（源码升级后必须重打）"
  local patcher="$SCRIPT_DIR/patches/apply-local-patches.py"
  [ -f "$patcher" ] || die "缺少补丁脚本：$patcher（应与本脚本同目录的 patches/ 下）"
  python3 "$patcher" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" || die "必要补丁失败，见 patches/README.md"
  python3 "$patcher" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" --check | tail -2
}

apply_feature_patches() {
  hr; echo "6) 可选功能补丁"
  local dir="$SCRIPT_DIR/patches/features"
  local found=0 picked=""
  if [ -d "$dir" ]; then
    for f in "$dir"/*/apply.sh; do
      [ -f "$f" ] || continue
      found=1
      local name desc
      name=$(basename "$(dirname "$f")")
      desc=$(head -n1 "$(dirname "$f")/README.md" 2>/dev/null || echo "$name")
      if ask_yes "应用功能补丁 [$name] ${desc} ?" n; then
        bash "$f" "$WORK" || die "功能补丁 $name 失败"
        picked="$picked $name"
        c_ok "已应用 $name"
      fi
    done
  fi
  [ "$found" = 0 ] && echo "当前没有可选功能补丁（把补丁放到 patches/features/<名称>/apply.sh 即可出现在这里）"
  FEATURES="$picked"; save_state
}

build_server() {
  hr; echo "7) 构建服务端镜像"
  cd "$WORK/ServerS5A3" || die "源码不存在"
  sg docker -c "docker build -t servers5a3-local:dev -f deploy/docker/Dockerfile ." || die "服务端镜像构建失败"
  c_ok "servers5a3-local:dev 构建完成"
}

prepare_server() {
  hr; echo "8) 生成服务端运行配置（120 频道外部 ETC）"
  [ -n "${BIND_IP:-}" ] || die "请先在菜单 4 选择部署方式"
  [ -f "$WORK/assets/Script.pvf" ] || die "缺少 PVF：$WORK/assets/Script.pvf（先上传）"
  local ch="$WORK/ServerS5A3/go-server/internal/services/dnfbridge/testdata/channel_info.etc"
  cd "$WORK/ServerS5A3"
  local envprefix=""
  is_rfc1918 "$BIND_IP" || envprefix="env DNF_ALLOW_PUBLIC_HOST=1"
  sg docker -c "cd $WORK/ServerS5A3 && $envprefix sh deploy/docker/manage.sh prepare --pvf $WORK/assets/Script.pvf --channel-info $ch --host-ip $BIND_IP" || die "prepare 失败"
  python3 - "$WORK/ServerS5A3/runtime/docker/instance.json" "${PUBLIC_IP:-$BIND_IP}" <<'PY'
import json, secrets, sys
from pathlib import Path
p = Path(sys.argv[1]); pub = sys.argv[2]
c = json.loads(p.read_text())
if not c.get("player_admin_secret"):
    c["player_admin_secret"] = secrets.token_hex(32)
c.update({
    "joust_event_enabled": False,
    "dungeon_tournament": "vendor",
    "channel_directory_owner_range": "u8",
    "channel_advertise_server": 1,
    "public_bootstrap": True,
    "restart": "unless-stopped",
    "advertise_ip": "" if pub == c["host_ip"] else pub,
})
p.write_text(json.dumps(c, indent=2) + "\n")
print("instance.json:", {k: c[k] for k in ("host_ip","advertise_ip","joust_event_enabled","dungeon_tournament","public_bootstrap")})
PY
  c_ok "prepare 完成，频道数见 manifest"
}

up_server() {
  hr; echo "9) 启动游戏服务"
  cd "$WORK/ServerS5A3"
  sg docker -c "cd $WORK/ServerS5A3 && sh deploy/docker/manage.sh up" || die "启动失败"
  for i in $(seq 1 60); do
    sleep 5
    curl -s --max-time 4 http://127.0.0.1:17002/api/status | grep -q '"ok":true' && break
  done
  curl -s --max-time 5 http://127.0.0.1:17002/api/status || die "账号 API 未就绪"
  c_ok "游戏服务已启动"
}

pm_inputs() {
  hr; echo "10) 生成 PurpleMagic 配置（证书/签名/profile/settings）"
  [ -n "${PUBLIC_IP:-}" ] || die "请先在菜单 4 选择部署方式"
  cd "$WORK/PurpleMagic"
  umask 077
  mkdir -p runtime/launcher-input runtime/client-input
  cp -f "$WORK/assets/Script.pvf" runtime/client-input/Script.pvf
  [ -f runtime/client-input/DNF.exe ] || c_warn "缺少 client-input/DNF.exe，请从客户端复制后再继续"
  [ -f runtime/client-input/DNF.exe ] || return 1

  cat > runtime/launcher-input/server.json <<JSON
{
  "ApiUrl": "https://${PLAYERS_HOST}:8443",
  "GameHost": "${PUBLIC_IP}",
  "BootstrapPort": 7001,
  "ChannelServerId": 1,
  "MinimumLauncherVersion": "0.2.20",
  "DefaultClientDirectory": ""
}
JSON

  local san
  if [ "$DEPLOY_MODE" = ip ]; then san="IP:${PUBLIC_IP}"; else san="DNS:${PLAYERS_HOST},DNS:${GM_HOST}"; fi
  if [ "${FORCE_CERT:-0}" = 1 ] || [ ! -f runtime/launcher-input/local-tls.pem ] || ask_yes "重新生成自签证书（覆盖现有）？" n; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
      -keyout runtime/launcher-input/local-tls-key.pem -out runtime/launcher-input/local-tls.pem \
      -subj "/CN=${PLAYERS_HOST}" -addext "subjectAltName=${san}" \
      -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
    c_ok "证书生成完成（SAN=${san}）"
  fi
  if [ ! -f runtime/launcher-input/signing-key.pem ]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out runtime/launcher-input/signing-key.pem 2>/dev/null
    openssl pkey -in runtime/launcher-input/signing-key.pem -pubout -out runtime/launcher-input/update-public.pem 2>/dev/null
  fi
  [ -f runtime/launcher-input/profile.json ] && mv runtime/launcher-input/profile.json "runtime/launcher-input/profile-$(date +%Y%m%d-%H%M%S).json"
  python3 scripts/prepare_launcher_profile.py \
    --connection runtime/launcher-input/server.json \
    --client runtime/client-input \
    --certificate runtime/launcher-input/local-tls.pem \
    --public-key runtime/launcher-input/update-public.pem \
    --output runtime/launcher-input/profile.json || die "profile 生成失败"

  python3 - "$WORK" "$GM_HOST" <<'PY'
import json, sys
from pathlib import Path
work = Path(sys.argv[1]); gm = sys.argv[2]
inst = json.loads((work/'ServerS5A3/runtime/docker/instance.json').read_text())
root = work/'PurpleMagic'; launcher = root/'runtime/launcher-input'
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
print('settings:', s['gmOrigin'])
PY
  c_ok "profile 与 settings 已生成"
}

build_pm() {
  hr; echo "11) 构建 PurpleMagic 镜像"
  cd "$WORK/PurpleMagic"
  [ -f runtime/selfhost/compose.env ] || die "请先生成 selfhost 配置（菜单 12）"
  sg docker -c "cd $WORK/PurpleMagic && docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml build" || die "网关镜像构建失败"
  c_ok "purplemagic:local 构建完成"
}

prepare_pm() {
  hr; echo "12) 生成 PurpleMagic 运行目录"
  cd "$WORK/PurpleMagic"
  [ -f runtime/selfhost-settings.json ] || die "缺少 settings，请先执行菜单 10"
  [ -d runtime/selfhost ] && mv runtime/selfhost "runtime/selfhost-bak-$(date +%Y%m%d-%H%M%S)"
  python3 deploy/selfhost/prepare.py --settings runtime/selfhost-settings.json --output runtime/selfhost || die "prepare.py 失败"
  c_ok "runtime/selfhost 已生成"
}

pm_index() {
  hr; echo "13) 建索引与管理表（PVF 大时约 10-25 分钟）"
  cd "$WORK/PurpleMagic"
  local C=(docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml)
  for step in index-pvf index-items index-quests index-professions schema; do
    echo "-- $step"
    sg docker -c "cd $WORK/PurpleMagic && ${C[*]} --profile setup run --rm $step" || die "$step 失败"
  done
  c_ok "索引与管理表完成"
}

start_pm() {
  hr; echo "14) 启动 gateway / gm / edge"
  cd "$WORK/PurpleMagic"
  local C=(docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml)
  sg docker -c "cd $WORK/PurpleMagic && ${C[*]} up -d gateway gm edge" || die "启动失败"
  sleep 6
  sg docker -c "cd $WORK/PurpleMagic && ${C[*]} ps"
  c_ok "网关/GM 已启动"
}

run_verify() {
  hr; echo "15) 自检"
  if [ -f "$WORK/ops/ops-verify.sh" ]; then bash "$WORK/ops/ops-verify.sh"; else
    curl -s --max-time 5 http://127.0.0.1:17002/api/status; echo
    [ -f "$CA" ] && curl -s --max-time 6 --cacert "$CA" "https://${PLAYERS_HOST:-127.0.0.1}:8443/api/status"; echo
    echo "频道端口数：$(ss -lnt | grep -c "${BIND_IP:-192.168.200.130}:10")"
  fi
}

install_ops() {
  mkdir -p "$WORK/ops"
  for f in "$SCRIPT_DIR"/ops-*.sh; do [ -f "$f" ] && cp -f "$f" "$WORK/ops/"; done
  chmod +x "$WORK"/ops/*.sh 2>/dev/null || true
  if [ -f "$SCRIPT_DIR/dnf-backup.service" ] && [ -f "$SCRIPT_DIR/dnf-backup.timer" ]; then
    sudo cp -f "$SCRIPT_DIR/dnf-backup.service" "$SCRIPT_DIR/dnf-backup.timer" /etc/systemd/system/ 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl enable --now dnf-backup.timer 2>/dev/null || true
  fi
}

full_deploy() {
  hr; echo "完整一键部署"
  menu_install
  menu_mirrors
  [ -n "${SOURCE_KIND:-}" ] || menu_source
  [ -n "${DEPLOY_MODE:-}" ] || menu_address
  apply_required_patches
  apply_feature_patches
  build_server
  prepare_server
  up_server
  FORCE_CERT=1
  pm_inputs || die "PurpleMagic 输入不完整（检查 runtime/client-input/DNF.exe）"
  prepare_pm
  build_pm
  pm_index
  start_pm
  install_ops
  run_verify
  echo
  c_ok "部署完成"
  echo "管理员 Token：$(cat "$WORK/PurpleMagic/runtime/selfhost/admin-token.txt" 2>/dev/null)"
  echo "登录器 profile：$WORK/PurpleMagic/runtime/launcher-input/profile.json（Windows 侧用它构建登录器）"
  echo "自检：bash $WORK/ops/ops-verify.sh"
}

menu_status() {
  hr; echo "10) 状态/日志/备份/自检"
  echo "  1) 状态与端口   2) 服务端日志   3) 网关日志   4) 立即备份   5) 自检"
  local n; n=$(ask "请选择" "1")
  case "$n" in
    1) [ -x "$WORK/ops/ops-status.sh" ] && bash "$WORK/ops/ops-status.sh" || docker ps;;
    2) [ -x "$WORK/ops/ops-logs.sh" ] && bash "$WORK/ops/ops-logs.sh" server || docker logs --tail 100 servers5a3-local-server-1;;
    3) [ -x "$WORK/ops/ops-logs.sh" ] && bash "$WORK/ops/ops-logs.sh" all || true;;
    4) [ -x "$WORK/ops/ops-backup.sh" ] && bash "$WORK/ops/ops-backup.sh";;
    5) run_verify;;
    *) c_err "无效选择";;
  esac
}

menu_main() {
  load_state
  while true; do
    hr
    echo "DNF90 交互式部署  —  $(date '+%F %T')"
    hr
    echo "  1) 安装/检查 Docker 与运行环境"
    echo "  2) 配置镜像加速"
    echo "  3) 选择源码（本地 / Git）"
    echo "  4) 选择部署方式与地址（IP / 域名）"
    echo "  5) 打必要补丁（源码升级后必须重打）"
    echo "  6) 可选功能补丁"
    echo "  7) 构建服务端镜像"
    echo "  8) prepare 服务端配置（120 频道 ETC）"
    echo "  9) 启动游戏服务"
    echo " 10) 生成 PurpleMagic 配置（证书/profile/settings）"
    echo " 11) 构建 PurpleMagic 镜像"
    echo " 12) 生成 PurpleMagic 运行目录"
    echo " 13) 建索引与管理表"
    echo " 14) 启动 gateway/gm/edge"
    echo " 15) 完整一键部署（1→14 串联）"
    echo " 16) 状态/日志/备份/自检"
    echo "  0) 退出"
    hr
    [ -n "${DEPLOY_MODE:-}" ] && echo "当前配置：$DEPLOY_MODE  BIND_IP=${BIND_IP:-}  PUBLIC_IP=${PUBLIC_IP:-}  PLAYERS=${PLAYERS_HOST:-}"
    local choice; choice=$(ask "请输入功能编号" "15")
    case "$choice" in
      1) menu_install;; 2) menu_mirrors;; 3) menu_source;; 4) menu_address;;
      5) apply_required_patches;; 6) apply_feature_patches;; 7) build_server;;
      8) prepare_server;; 9) up_server;; 10) pm_inputs;; 11) build_pm;;
      12) prepare_pm;; 13) pm_index;; 14) start_pm;; 15) full_deploy;;
      16) menu_status;; 0) exit 0;; *) c_err "无效编号";;
    esac
    echo; read -rp "按回车返回菜单..." _ || exit 0
  done
}

self_test() {
  hr; echo "自测"
  echo "IP 检测："; detect_net
  for ip in 192.168.200.130 10.0.0.5 8.8.8.8 1.2.3.999 127.0.0.1; do
    valid_ipv4 "$ip" && echo "  valid_ipv4($ip)=yes" || echo "  valid_ipv4($ip)=no"
  done
  for d in example.com players.example.com bad_domain; do
    valid_domain "$d" && echo "  valid_domain($d)=yes" || echo "  valid_domain($d)=no"
  done
  echo "源码：ServerS5A3=$([ -d "$WORK/ServerS5A3/go-server" ] && echo yes || echo no) PurpleMagic=$([ -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ] && echo yes || echo no)"
  echo "补丁："; python3 "$SCRIPT_DIR/patches/apply-local-patches.py" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" --check 2>/dev/null | tail -2 || true
  echo "自测结束（未修改任何文件）"
}

case "${1:-}" in
  --self-test) self_test; exit 0;;
  --help|-h) sed -n '2,20p' "$0"; exit 0;;
esac
[ -f "$STATE" ] || save_state
menu_main
