#!/bin/bash
# =============================================================================
# DNF90 (ServerS5A3 + PurpleMagic) 交互式一键部署 — Linux 侧
#
#   bash deploy-oneclick.sh            # 显示部署计划，直接回车 = 按序号依次执行
#   bash deploy-oneclick.sh --self-test  # 只做环境/IP/校验自测，不改任何文件
#
# 主界面：
#   回车  = 依次执行 1→15
#   数字  = 只执行该步（排错用）
#   s     = 修改设置（源码 / 地址 / 镜像 / 功能补丁）
#   q     = 退出
# =============================================================================
set -uo pipefail

WORK=${DNF_WORK:-/srv/dnf}
STATE=$WORK/deploy.conf
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LOG_DIR=$WORK/logs
LOG=$LOG_DIR/deploy-$(date +%Y%m%d-%H%M%S).log
CA=$WORK/PurpleMagic/runtime/selfhost/tls-player/ca.pem
TOTAL_STEPS=15

mkdir -p "$LOG_DIR" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()    { c_err "错误：$*"; exit 1; }
hr()     { printf '%s\n' "------------------------------------------------------------"; }

ask() {
  local prompt=$1 def=${2:-} v
  if [ -n "$def" ]; then read -rp "$prompt [$def]: " v; v=${v:-$def}; else read -rp "$prompt: " v; fi
  printf '%s' "$v"
}
ask_yes() {
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
valid_domain() { [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; }

load_state() { [ -f "$STATE" ] && . "$STATE" || true; }
save_state() {
  {
    echo "DEPLOY_MODE=${DEPLOY_MODE:-}"
    echo "BIND_IP=${BIND_IP:-}"
    echo "PUBLIC_IP=${PUBLIC_IP:-}"
    echo "PLAYERS_HOST=${PLAYERS_HOST:-}"
    echo "GM_HOST=${GM_HOST:-}"
    echo "SOURCE_KIND=${SOURCE_KIND:-}"
    echo "MIRRORS=${MIRRORS:-yes}"
    echo "DOMAIN_BASE=${DOMAIN_BASE:-}"
    echo "FEATURES=${FEATURES:-}"
  } > "$STATE"
  chmod 600 "$STATE"
}

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

# ---------------------------------------------------------------- 1 环境
fn_env() {
  hr; echo "步骤 1/15：安装/检查 Docker 与运行环境"
  local need=0
  for c in docker git python3 openssl curl; do command -v $c >/dev/null || { c_warn "缺少 $c"; need=1; }; done
  if [ "$need" = 0 ] && sg docker -c "docker info >/dev/null" 2>/dev/null; then c_ok "环境已就绪"; return 0; fi
  sudo -n true 2>/dev/null || { c_err "需要免密 sudo（NOPASSWD）"; return 1; }

  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg git jq unzip openssl python3 >/dev/null

  if ! command -v docker >/dev/null; then
    echo "-> 安装 Docker CE（阿里云源，失败回退官方源）"
    sudo install -m 0755 -d /etc/apt/keyrings
    local ok=0
    for i in 1 2 3; do
      curl -fsSL --retry 3 --connect-timeout 10 https://mirrors.aliyun.com/docker-ce/linux/ubuntu/gpg -o /tmp/docker.gpg && ok=1 && break
      curl -fsSL --retry 3 --connect-timeout 10 https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.gpg && ok=1 && break
      sleep 3
    done
    [ "$ok" = 1 ] || { c_err "Docker GPG 下载失败，请检查网络"; return 1; }
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
  sg docker -c "docker info >/dev/null" 2>/dev/null || { c_err "当前用户无法访问 Docker，请重新登录后重试"; return 1; }
  c_ok "Docker $(docker --version | awk '{print $3}') / Compose $(docker compose version --short 2>/dev/null)"
}

# ---------------------------------------------------------------- 2 镜像
fn_mirrors() {
  hr; echo "步骤 2/15：配置镜像加速（MIRRORS=${MIRRORS:-yes}）"
  if [ "${MIRRORS:-yes}" != "yes" ]; then echo "已跳过（设置里可开启）"; return 0; fi
  sudo -n true 2>/dev/null || { c_err "需要免密 sudo"; return 1; }
  if [ ! -f /etc/docker/daemon.json ] || ! grep -q 'registry-mirrors' /etc/docker/daemon.json; then
    sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1ms.run", "https://dockerproxy.net"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
EOF
    sudo systemctl restart docker
    c_ok "已写入 Docker 镜像加速"
  else
    echo "Docker 镜像加速已存在，跳过"
  fi
  if [ "${APT_MIRROR:-no}" = "yes" ]; then
    sudo sed -i 's|http://archive.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g; s|http://security.ubuntu.com/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|g' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
    sudo apt-get update -qq
    c_ok "apt 源已切换清华"
  fi
}

# ---------------------------------------------------------------- 3 源码
git_net_check() {
  curl -sI --max-time 8 https://github.com >/dev/null 2>&1 && return 0
  c_warn "访问 github.com 失败或超时，克隆可能失败；可改用本地源码（设置 → 源码方式）"
  return 1
}

clone_or_pull() { # clone_or_pull <url> <dir> <名称> <标志文件>
  local url=$1 dst=$2 name=$3 marker=$4
  if [ -d "$dst/.git" ]; then
    echo "-> $name 已是 Git 仓库，尝试更新"
    if (cd "$dst" && timeout 300 env GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
         git -c http.version=HTTP/1.1 pull --ff-only 2>&1); then
      c_ok "$name 更新完成"
    else
      c_warn "$name 更新失败，继续使用现有源码"
    fi
    return 0
  fi
  if [ -d "$dst" ] && [ -f "$dst/$marker" ]; then
    c_warn "$dst 已存在但不是 Git 仓库，直接作为本地源码使用"
    return 0
  fi
  rm -rf "$dst"
  git_net_check || true
  local i
  for i in 1 2 3; do
    echo "-> 克隆 $name（第 $i/3 次，超时 600 秒，可用 Ctrl+C 取消）"
    if timeout 600 env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
         GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
         git -c http.version=HTTP/1.1 clone --depth 1 --progress "$url" "$dst" 2>&1; then
      c_ok "$name 克隆完成"
      return 0
    fi
    c_warn "第 $i 次失败/超时"
    rm -rf "$dst"
    sleep 3
  done
  c_err "$name 克隆失败。可改用本地源码：设置(s) → 源码方式 → 1 本地源码，按提示上传。"
  return 1
}

fn_source() {
  hr; echo "步骤 3/15：准备源码"
  [ -n "${SOURCE_KIND:-}" ] || { c_err "尚未选择源码方式，请按 s 进入设置"; return 1; }
  if [ "$SOURCE_KIND" = "git" ]; then
    clone_or_pull https://github.com/Cec1c/ServerS5A3.git "$WORK/ServerS5A3" ServerS5A3 AGENTS.md || return 1
    clone_or_pull https://github.com/Cec1c/PurpleMagic.git "$WORK/PurpleMagic" PurpleMagic deploy/selfhost/prepare.py || return 1
  else
    local ok=1
    [ -f "$WORK/ServerS5A3/AGENTS.md" ] && [ -d "$WORK/ServerS5A3/go-server" ] || { c_err "缺少 $WORK/ServerS5A3（AGENTS.md / go-server）"; ok=0; }
    [ -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ] || { c_err "缺少 $WORK/PurpleMagic（deploy/selfhost/prepare.py）"; ok=0; }
    [ "$ok" = 1 ] || { echo "请上传源码到 $WORK/，或重新运行本脚本选择本地源码（菜单 s）"; return 1; }
  fi
  [ -d "$WORK/ServerS5A3/.git" ] && echo "ServerS5A3: $(cd "$WORK/ServerS5A3" && git rev-parse --short HEAD)"
  [ -d "$WORK/PurpleMagic/.git" ] && echo "PurpleMagic: $(cd "$WORK/PurpleMagic" && git rev-parse --short HEAD)"
  c_ok "源码就绪"
}

# ---------------------------------------------------------------- 4 地址
fn_address() {
  hr; echo "步骤 4/15：部署方式与地址"
  if [ -n "${DEPLOY_MODE:-}" ] && [ -n "${PUBLIC_IP:-}" ]; then
    echo "使用已保存配置：$DEPLOY_MODE  BIND_IP=$BIND_IP  PUBLIC_IP=$PUBLIC_IP  PLAYERS=$PLAYERS_HOST"
    return 0
  fi
  detect_net
  echo "  1) IP 直连（无域名，推荐）"
  echo "  2) 域名访问"
  local mode; mode=$(ask "请选择" "1")
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
      PLAYERS_HOST=$PUBLIC_IP; GM_HOST=$PUBLIC_IP; DEPLOY_MODE=ip; DOMAIN_BASE=""
      ;;
    2)
      while true; do
        DOMAIN_BASE=$(ask "请输入主域名（示例 example.com，将使用 players.example.com / gm.example.com）" "${DOMAIN_BASE:-}")
        valid_domain "$DOMAIN_BASE" && break
        c_err "域名格式不合法，示例：example.com"
      done
      PLAYERS_HOST="players.$DOMAIN_BASE"; GM_HOST="gm.$DOMAIN_BASE"
      while true; do
        PUBLIC_IP=$(ask "请输入服务器 IP（玩家直连游戏用）" "${PUBLIC_IP:-$DEFAULT_IP}")
        valid_ipv4 "$PUBLIC_IP" && break
        c_err "IP 不合法"
      done
      if is_local_ip "$PUBLIC_IP"; then BIND_IP=$PUBLIC_IP; else BIND_IP=$DEFAULT_IP; c_warn "公网 IP 不在网卡上，绑定用 $BIND_IP"; fi
      DEPLOY_MODE=domain
      c_warn "域名模式需要：A 记录 players.$DOMAIN_BASE / gm.$DOMAIN_BASE 指向公网 IP；证书需覆盖这两个域名"
      ;;
    *) c_err "无效选择"; return 1;;
  esac
  save_state
  c_ok "部署方式：$DEPLOY_MODE  BIND_IP=$BIND_IP  公网/玩家地址=$PUBLIC_IP"
}

# ---------------------------------------------------------------- 5/6 补丁
fn_required_patches() {
  hr; echo "步骤 5/15：打必要补丁（源码升级后必须重打）"
  local patcher="$SCRIPT_DIR/patches/apply-local-patches.py"
  [ -f "$patcher" ] || { c_err "缺少补丁脚本：$patcher"; return 1; }
  python3 "$patcher" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" || { c_err "必要补丁失败，见 patches/README.md"; return 1; }
  python3 "$patcher" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" --check | tail -1
}

fn_feature_patches() {
  hr; echo "步骤 6/15：可选功能补丁（${FEATURES:-无}）"
  local dir="$SCRIPT_DIR/patches/features"
  [ -n "${FEATURES:-}" ] || { echo "未选择功能补丁，跳过"; return 0; }
  local f
  for f in $FEATURES; do
    if [ -f "$dir/$f/apply.sh" ]; then
      echo "-> 应用 $f"
      bash "$dir/$f/apply.sh" "$WORK" || { c_err "功能补丁 $f 失败"; return 1; }
    else
      c_err "功能补丁不存在：$f"; return 1
    fi
  done
  c_ok "功能补丁完成"
}

# ---------------------------------------------------------------- 7-15 部署
fn_build_server() {
  hr; echo "步骤 7/15：构建服务端镜像"
  cd "$WORK/ServerS5A3" || { c_err "源码不存在"; return 1; }
  sg docker -c "docker build -t servers5a3-local:dev -f deploy/docker/Dockerfile ." || { c_err "镜像构建失败"; return 1; }
  c_ok "servers5a3-local:dev 构建完成"
}

fn_prepare() {
  hr; echo "步骤 8/15：生成服务端运行配置（120 频道外部 ETC）"
  [ -n "${BIND_IP:-}" ] || { c_err "请先设置部署地址（步骤 4）"; return 1; }
  if [ ! -f "$WORK/assets/Script.pvf" ]; then
    c_err "缺少 PVF：$WORK/assets/Script.pvf"
    echo "上传：scp Script.pvf ubuntu@<服务器IP>:$WORK/assets/"
    return 1
  fi
  if [ -f "$WORK/ServerS5A3/runtime/docker/data/Script.pvf" ] && \
     ! cmp -s "$WORK/assets/Script.pvf" "$WORK/ServerS5A3/runtime/docker/data/Script.pvf"; then
    echo "-> 检测到 PVF 变化，备份旧运行副本"
    mv "$WORK/ServerS5A3/runtime/docker/data/Script.pvf" \
       "$WORK/ServerS5A3/runtime/docker/data/Script.pvf.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  local ch="$WORK/ServerS5A3/go-server/internal/services/dnfbridge/testdata/channel_info.etc"
  local envprefix=""
  is_rfc1918 "$BIND_IP" || envprefix="env DNF_ALLOW_PUBLIC_HOST=1"
  sg docker -c "cd $WORK/ServerS5A3 && $envprefix sh deploy/docker/manage.sh prepare --pvf $WORK/assets/Script.pvf --channel-info $ch --host-ip $BIND_IP" || { c_err "prepare 失败"; return 1; }
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
  c_ok "prepare 完成"
}

fn_up_server() {
  hr; echo "步骤 9/15：启动游戏服务"
  cd "$WORK/ServerS5A3" || return 1
  sg docker -c "cd $WORK/ServerS5A3 && sh deploy/docker/manage.sh up" || { c_err "启动失败"; return 1; }
  local i
  for i in $(seq 1 60); do
    sleep 5
    curl -s --max-time 4 http://127.0.0.1:17002/api/status | grep -q '"ok":true' && break
  done
  curl -s --max-time 5 http://127.0.0.1:17002/api/status || { c_err "账号 API 未就绪"; return 1; }
  c_ok "游戏服务已启动"
}

fn_pm_inputs() {
  hr; echo "步骤 10/15：生成 PurpleMagic 配置（证书/签名/profile/settings）"
  [ -n "${PUBLIC_IP:-}" ] || { c_err "请先设置部署地址"; return 1; }
  cd "$WORK/PurpleMagic" || return 1
  umask 077
  mkdir -p runtime/launcher-input runtime/client-input
  cp -f "$WORK/assets/Script.pvf" runtime/client-input/Script.pvf
  if [ ! -f runtime/client-input/DNF.exe ]; then
    c_err "缺少 runtime/client-input/DNF.exe"
    echo "上传：scp DNF.exe ubuntu@<服务器IP>:$WORK/PurpleMagic/runtime/client-input/"
    return 1
  fi

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
  local need_cert=0
  if [ "${FORCE_CERT:-0}" = 1 ] || [ ! -f runtime/launcher-input/local-tls.pem ]; then
    need_cert=1
  elif [ "$DEPLOY_MODE" = ip ]; then
    openssl x509 -in runtime/launcher-input/local-tls.pem -noout -checkip "$PUBLIC_IP" >/dev/null 2>&1 || need_cert=1
  else
    openssl x509 -in runtime/launcher-input/local-tls.pem -noout -checkhost "$PLAYERS_HOST" >/dev/null 2>&1 || need_cert=1
  fi
  if [ "$need_cert" = 1 ]; then
    openssl req -x509 -newkey rsa:3072 -nodes -days 3650 \
      -keyout runtime/launcher-input/local-tls-key.pem -out runtime/launcher-input/local-tls.pem \
      -subj "/CN=${PLAYERS_HOST}" -addext "subjectAltName=${san}" \
      -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null
    c_ok "证书生成完成（SAN=${san}）"
  else
    echo "证书与当前地址匹配，保留现有证书（要重签：删除 local-tls.pem 或设置 FORCE_CERT=1）"
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
    --output runtime/launcher-input/profile.json || { c_err "profile 生成失败"; return 1; }

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

fn_prepare_pm() {
  hr; echo "步骤 11/15：生成 PurpleMagic 运行目录"
  cd "$WORK/PurpleMagic" || return 1
  [ -f runtime/selfhost-settings.json ] || { c_err "缺少 settings（先执行步骤 10）"; return 1; }
  [ -d runtime/selfhost ] && mv runtime/selfhost "runtime/selfhost-bak-$(date +%Y%m%d-%H%M%S)"
  python3 deploy/selfhost/prepare.py --settings runtime/selfhost-settings.json --output runtime/selfhost || { c_err "prepare.py 失败"; return 1; }
  c_ok "runtime/selfhost 已生成"
}

fn_build_pm() {
  hr; echo "步骤 12/15：构建 PurpleMagic 镜像"
  cd "$WORK/PurpleMagic" || return 1
  [ -f runtime/selfhost/compose.env ] || { c_err "请先执行步骤 11"; return 1; }
  sg docker -c "cd $WORK/PurpleMagic && docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml build" || { c_err "网关镜像构建失败"; return 1; }
  c_ok "purplemagic:local 构建完成"
}

fn_index() {
  hr; echo "步骤 13/15：建索引与管理表（PVF 大时约 10-25 分钟）"
  cd "$WORK/PurpleMagic" || return 1
  local C=(docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml)
  local step
  for step in index-pvf index-items index-quests index-professions schema; do
    echo "-- $step"
    sg docker -c "cd $WORK/PurpleMagic && ${C[*]} --profile setup run --rm $step" || { c_err "$step 失败"; return 1; }
  done
  c_ok "索引与管理表完成"
}

fn_start_pm() {
  hr; echo "步骤 14/15：启动 gateway / gm / edge"
  cd "$WORK/PurpleMagic" || return 1
  local C=(docker compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml)
  sg docker -c "cd $WORK/PurpleMagic && ${C[*]} up -d gateway gm edge" || { c_err "启动失败"; return 1; }
  sleep 6
  sg docker -c "cd $WORK/PurpleMagic && ${C[*]} ps"
  c_ok "网关/GM 已启动"
}

fn_verify() {
  hr; echo "步骤 15/15：自检"
  install_ops
  if [ -f "$WORK/ops/ops-verify.sh" ]; then
    bash "$WORK/ops/ops-verify.sh"
  else
    curl -s --max-time 5 http://127.0.0.1:17002/api/status; echo
    echo "频道端口数：$(ss -lnt | grep -c "${BIND_IP}:10")"
  fi
  echo "管理员 Token：$(cat "$WORK/PurpleMagic/runtime/selfhost/admin-token.txt" 2>/dev/null)"
  echo "登录器 profile：$WORK/PurpleMagic/runtime/launcher-input/profile.json"
}

install_ops() {
  mkdir -p "$WORK/ops"
  local f
  for f in "$SCRIPT_DIR"/ops-*.sh; do [ -f "$f" ] && cp -f "$f" "$WORK/ops/"; done
  chmod +x "$WORK"/ops/*.sh 2>/dev/null || true
  if [ -f "$SCRIPT_DIR/dnf-backup.service" ] && [ -f "$SCRIPT_DIR/dnf-backup.timer" ]; then
    sudo cp -f "$SCRIPT_DIR/dnf-backup.service" "$SCRIPT_DIR/dnf-backup.timer" /etc/systemd/system/ 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    sudo systemctl enable --now dnf-backup.timer 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------- 计划与设置
plan_line() { printf "  %-2s %-28s %s\n" "$1" "$2" "$3"; }
print_plan() {
  hr
  echo "DNF90 部署计划  —  $(date '+%F %T')"
  hr
  local env_state="待执行"; command -v docker >/dev/null && sg docker -c "docker info >/dev/null" 2>/dev/null && env_state="已就绪"
  local src_state="未选择"
  [ "$SOURCE_KIND" = git ] && src_state="Git: $WORK/ServerS5A3"
  [ "$SOURCE_KIND" = local ] && src_state="本地: $WORK/ServerS5A3"
  local addr_state="未设置"
  [ -n "${DEPLOY_MODE:-}" ] && addr_state="$DEPLOY_MODE  $PUBLIC_IP"
  local feat_state="${FEATURES:-无}"
  plan_line 1 "环境检查与安装" "$env_state"
  plan_line 2 "镜像加速" "${MIRRORS:-yes}"
  plan_line 3 "准备源码" "$src_state"
  plan_line 4 "部署地址" "$addr_state"
  plan_line 5 "必要补丁（11 项）" "自动"
  plan_line 6 "功能补丁" "$feat_state"
  plan_line 7 "构建服务端镜像" ""
  plan_line 8 "prepare 服务端配置" "120 频道 ETC"
  plan_line 9 "启动游戏服务" ""
  plan_line 10 "PurpleMagic 配置" "证书/profile/settings"
  plan_line 11 "生成网关运行目录" ""
  plan_line 12 "构建网关镜像" ""
  plan_line 13 "索引与管理表" "约 10-25 分钟"
  plan_line 14 "启动 gateway/gm/edge" ""
  plan_line 15 "自检并输出 Token" ""
  hr
}

run_step() {
  if [ "${DNF_DRY:-0}" = "1" ]; then echo "[dry] 步骤 $1"; return 0; fi
  case "$1" in
    1) fn_env;; 2) fn_mirrors;; 3) fn_source;; 4) fn_address;;
    5) fn_required_patches;; 6) fn_feature_patches;; 7) fn_build_server;;
    8) fn_prepare;; 9) fn_up_server;; 10) fn_pm_inputs;;
    11) fn_prepare_pm;; 12) fn_build_pm;; 13) fn_index;;
    14) fn_start_pm;; 15) fn_verify;;
    *) c_err "无效步骤 $1"; return 1;;
  esac
}

run_sequence() {
  hr; echo "开始依次执行 1→15（任一步失败会停止，之后可单独重跑该步）"
  local n
  for n in $(seq 1 "$TOTAL_STEPS"); do
    if ! run_step "$n"; then
      c_err "步骤 $n 失败，已停止。"
      echo "修复后：输入编号 $n 可单独重跑；输入 s 可改设置。"
      return 1
    fi
    echo
  done
  c_ok "全部步骤完成。"
}

settings_menu() {
  while true; do
    hr; echo "设置"
    echo "  1) 源码方式（当前：${SOURCE_KIND:-未选择}）"
    echo "  2) 部署方式与地址（当前：${DEPLOY_MODE:-未设置} ${PUBLIC_IP:-}）"
    echo "  3) 镜像加速（当前：${MIRRORS:-yes}）"
    echo "  4) 可选功能补丁（当前：${FEATURES:-无}）"
    echo "  5) 返回"
    local c; c=$(ask "请选择" "5")
    case "$c" in
      1)
        echo "  1) 本地源码（先上传到 $WORK/ServerS5A3 与 $WORK/PurpleMagic）"
        echo "  2) Git 拉取（GitHub，失败会自动重试/超时）"
        local k; k=$(ask "请选择" "2")
        case "$k" in
          1) SOURCE_KIND=local
             echo "上传示例："
             echo "  scp -r ServerS5A3  ubuntu@<服务器IP>:$WORK/"
             echo "  scp -r PurpleMagic ubuntu@<服务器IP>:$WORK/"
             ;;
          2) SOURCE_KIND=git;;
          *) c_err "无效"; continue;;
        esac
        save_state; c_ok "源码方式：$SOURCE_KIND"
        ;;
      2) DEPLOY_MODE=""; PUBLIC_IP=""; fn_address && save_state;;
      3)
        if [ "${MIRRORS:-yes}" = yes ]; then MIRRORS=no; else MIRRORS=yes; fi
        save_state; c_ok "镜像加速：$MIRRORS"
        ;;
      4)
        echo "可用功能补丁："
        local dir="$SCRIPT_DIR/patches/features" f any=0
        if [ -d "$dir" ]; then
          for f in "$dir"/*/apply.sh; do
            [ -f "$f" ] || continue
            any=1; echo "  - $(basename "$(dirname "$f")")"
          done
        fi
        [ "$any" = 0 ] && echo "  （当前没有可选功能补丁）"
        local picked; picked=$(ask "输入要启用的补丁名（空格分隔，留空=无）" "${FEATURES:-}")
        FEATURES="$picked"; save_state; c_ok "功能补丁：${FEATURES:-无}"
        ;;
      5) return 0;;
      *) c_err "无效选择";;
    esac
  done
}

main() {
  load_state
  while true; do
    print_plan
    echo "直接按回车 = 依次执行 1→15；输入编号 = 只执行该步；s = 修改设置；q = 退出"
    local ch; read -rp "> " ch || exit 0
    case "$ch" in
      "") run_sequence;;
      s|S) settings_menu;;
      q|Q) exit 0;;
      [0-9]|[0-9][0-9]) run_step "$ch" || true;;
      *) c_err "无效输入";;
    esac
    echo
    read -rp "按回车返回计划..." _ || exit 0
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
  echo "补丁："; python3 "$SCRIPT_DIR/patches/apply-local-patches.py" --server "$WORK/ServerS5A3" --purplemagic "$WORK/PurpleMagic" --check 2>/dev/null | tail -1 || true
  echo "自测结束（未修改任何文件）"
}

case "${1:-}" in
  --self-test) self_test; exit 0;;
  --help|-h) sed -n '2,18p' "$0"; exit 0;;
esac
[ -f "$STATE" ] || save_state
main
