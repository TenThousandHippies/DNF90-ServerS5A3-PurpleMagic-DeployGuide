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
SEQ_MODE=0

mkdir -p "$LOG_DIR" 2>/dev/null || true
exec > >(tee -a "$LOG") 2>&1

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()    { c_err "错误：$*"; exit 1; }
hr()     { printf '%s\n' "------------------------------------------------------------"; }

ask() {
  local prompt=$1 def=${2:-} v
  if [ -n "$def" ]; then printf '%s [%s]: ' "$prompt" "$def" >&2; else printf '%s: ' "$prompt" >&2; fi
  read -r v || { echo; return 1; }
  [ -z "$v" ] && v=$def
  printf '%s' "$v"
}
ask_yes() {
  local prompt=$1 def=${2:-n} v
  if [ "$def" = "y" ]; then printf '%s [Y/n]: ' "$prompt" >&2; else printf '%s [y/N]: ' "$prompt" >&2; fi
  read -r v || { echo; return 1; }
  [ -z "$v" ] && v=$def
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
    echo "REPO_OWNER=${REPO_OWNER:-Cec1c}"
    echo "PRESET=${PRESET:-yes}"
    echo "MIRRORS=${MIRRORS:-yes}"
    echo "DOMAIN_BASE=${DOMAIN_BASE:-}"
    echo "FEATURES=${FEATURES:-}"
  } > "$STATE"
  chmod 600 "$STATE"
}

ensure_dirs() {
  local missing=0 d
  for d in assets logs backups ops packages probe; do [ -d "$WORK/$d" ] || missing=1; done
  [ "$missing" = 1 ] || return 0
  if mkdir -p "$WORK"/{assets,logs,backups,ops,packages,probe} 2>/dev/null; then
    c_ok "已创建目录：$WORK/{assets,logs,backups,ops,packages,probe}"
  else
    sudo -n mkdir -p "$WORK"/{assets,logs,backups,ops,packages,probe} || { c_err "无法创建 $WORK 目录（需要 sudo）"; return 1; }
    sudo -n chown -R "$(id -u):$(id -g)" "$WORK" || true
    c_ok "已用 sudo 创建并授权目录"
  fi
}

find_input() {
  local n=$1 p
  for p in "$HOME/DNF90/$n" "$HOME/$n" "$WORK/$n" "$WORK/upload/$n" "$PWD/$n"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  for p in /home/*/"$n"; do
    [ -f "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

bootstrap_inputs() {
  mkdir -p "$WORK/assets" 2>/dev/null || true
  if [ ! -f "$WORK/assets/Script.pvf" ]; then
    local src
    if src=$(find_input Script.pvf); then cp -f "$src" "$WORK/assets/Script.pvf" && c_ok "已复制 Script.pvf ← $src"; fi
  fi
  if [ ! -f "$WORK/assets/DNF.exe" ]; then
    local src
    if src=$(find_input DNF.exe); then cp -f "$src" "$WORK/assets/DNF.exe" && c_ok "已复制 DNF.exe ← $src"; fi
  fi
}

extract_zip() { # <zip> <目标目录>
  python3 - "$1" "$2" <<'PY' || return 1
import sys, os, zipfile
src, dst = sys.argv[1], sys.argv[2]
base = os.path.realpath(dst)
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        name = info.filename.replace('\\', '/')
        target = os.path.realpath(os.path.join(base, name))
        if not (target == base or target.startswith(base + os.sep)):
            raise SystemExit('unsafe path: ' + name)
        if name.endswith('/'):
            os.makedirs(target, exist_ok=True); continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with z.open(info) as f, open(target, 'wb') as o:
            o.write(f.read())
print('extracted', len(z.namelist()), 'entries')
PY
}

unpack_archive() { # <名称> <zip> <标志文件>
  local name=$1 zip=$2 marker=$3 inner
  [ -f "$zip" ] || { c_err "缺少压缩包：$zip"; return 1; }
  if [ -f "$WORK/$name/$marker" ]; then echo "$name 已存在，保留现有源码"; return 0; fi
  echo "-> 解压 $name"
  rm -rf "$WORK/.unpack-$name"; mkdir -p "$WORK/.unpack-$name"
  extract_zip "$zip" "$WORK/.unpack-$name" || { c_err "解压失败：$zip"; return 1; }
  inner=$(find "$WORK/.unpack-$name" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$inner" ] || { c_err "压缩包结构异常：$zip"; return 1; }
  mkdir -p "$WORK/$name"; cp -a "$inner"/. "$WORK/$name"/
  rm -rf "$WORK/.unpack-$name"
  c_ok "$name 已解压到 $WORK/$name"
}

download_zip() { # <url> <out>
  local url=$1 out=$2
  mkdir -p "$(dirname "$out")"
  echo "-> 下载 $(basename "$out")（支持断点续传）"
  rm -f "$out.part"
  if ! curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -C - -o "$out.part" "$url"; then
    rm -f "$out.part"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -o "$out.part" "$url" || { rm -f "$out.part"; return 1; }
  fi
  mv "$out.part" "$out"
  c_ok "$(basename "$out") 下载完成（$(du -h "$out" | cut -f1)）"
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
  hr; echo "步骤 2/15：配置镜像加速"
  if [ "${SEQ_MODE:-0}" = 1 ]; then
    local def=y; [ "${MIRRORS:-yes}" = "no" ] && def=n
    if ask_yes "是否配置 Docker 镜像加速（国内建议 y）？" "$def"; then MIRRORS=yes; else MIRRORS=no; fi
    save_state
  fi
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
  # 只做提示，不阻塞：用 ls-remote 探测（HEAD 被墙时 git 仍可能可用）
  if ! timeout 15 env GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$1" >/dev/null 2>&1; then
    c_warn "git ls-remote 探测失败（不影响继续尝试；网络慢时会自动重试）"
  fi
}

clone_or_pull() { # <url> <dir> <名称> <标志文件> <分支>
  local url=$1 dst=$2 name=$3 marker=$4 branch=$5
  if [ -d "$dst" ] && { [ -f "$dst/$marker" ] || [ -f "$dst/deploy/docker/manage.py" ] || [ -f "$dst/runtime/docker/instance.json" ]; }; then
    c_warn "$dst 已存在（源码或部署目录），直接作为本地源码使用，不删除"
    return 0
  fi
  if [ -d "$dst" ] && [ -n "$(ls -A "$dst" 2>/dev/null)" ] && [ ! -d "$dst/.git" ]; then
    c_err "$dst 存在但不是可识别的源码目录；为避免误删已停止，请手动检查后移走"
    return 1
  fi

  mkdir -p "$dst"
  [ -d "$dst/.git" ] || git -C "$dst" init -q
  if git -C "$dst" remote get-url origin >/dev/null 2>&1; then
    git -C "$dst" remote set-url origin "$url"
  else
    git -C "$dst" remote add origin "$url"
  fi

  local timeout_s=${GIT_FETCH_TIMEOUT:-3600}
  local i
  for i in 1 2 3; do
    echo "-> 拉取 $name（第 $i/3 次，单次上限 ${timeout_s}s；Git 不支持断点续传，失败会重试）"
    if timeout "$timeout_s" env GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
         GIT_HTTP_LOW_SPEED_LIMIT=${GIT_LOW_SPEED_LIMIT:-0} \
         GIT_HTTP_LOW_SPEED_TIME=${GIT_LOW_SPEED_TIME:-0} \
         git -C "$dst" -c http.version=HTTP/1.1 -c http.postBuffer=524288000 \
         fetch --depth 1 --progress origin "$branch" 2>&1; then
      git -C "$dst" checkout -q -f FETCH_HEAD && git -C "$dst" reset -q --hard FETCH_HEAD
      if [ -f "$dst/$marker" ]; then c_ok "$name 拉取完成"; return 0; fi
      c_warn "$name 拉取完成但缺少 $marker，继续重试"
    else
      c_warn "第 $i 次失败/超时（网络慢可加大 GIT_FETCH_TIMEOUT）"
    fi
    sleep 3
  done
  c_err "$name 拉取失败。可改用离线包或本地上传；已保留 $dst/.git 便于下次重试"
  return 1
}

fn_source() {
  hr; echo "步骤 3/15：准备源码"
  if [ "${SEQ_MODE:-0}" = 1 ]; then
    local cur=3
    case "${SOURCE_KIND:-}" in local) cur=1;; packages) cur=2;; zip) cur=3;; git) cur=4;; esac
    echo "  1) 本地源码（目录已就绪，或自己 scp 上传）"
    echo "  2) 离线源码包（$WORK/packages/*.zip）"
    echo "  3) GitHub ZIP 下载（codeload，支持断点续传；推荐）"
    echo "  4) Git 拉取（fetch --depth 1）"
    local k; k=$(ask "请选择源码方式" "$cur")
    case "$k" in
      1) SOURCE_KIND=local ;;
      2) SOURCE_KIND=packages ;;
      3) SOURCE_KIND=zip ;;
      4) SOURCE_KIND=git ;;
      *) c_err "无效选择"; return 1 ;;
    esac
    save_state
    if [ "$SOURCE_KIND" = "zip" ] || [ "$SOURCE_KIND" = "git" ]; then
      echo "  1) Cec1c（原作者）"
      echo "  2) TenThousandHippies（fork）"
      local owner_cur=1
      [ "${REPO_OWNER:-Cec1c}" = "TenThousandHippies" ] && owner_cur=2
      local po; po=$(ask "请选择源码仓库" "$owner_cur")
      if [ "$po" = "2" ]; then REPO_OWNER=TenThousandHippies; else REPO_OWNER=Cec1c; fi
      save_state
    fi
  elif [ -z "${SOURCE_KIND:-}" ]; then
    c_err "尚未选择源码方式"; return 1
  fi

  if [ "$SOURCE_KIND" = "packages" ] || [ "$SOURCE_KIND" = "zip" ]; then
    mkdir -p "$WORK/packages"
    if [ "$SOURCE_KIND" = "zip" ]; then
      local owner="${REPO_OWNER:-Cec1c}"
      local s5a="https://codeload.github.com/$owner/ServerS5A3/zip/refs/heads/master"
      local s5b="https://codeload.github.com/$owner/ServerS5A3/zip/refs/heads/main"
      local pma="https://codeload.github.com/$owner/PurpleMagic/zip/refs/heads/main"
      local pmb="https://codeload.github.com/$owner/PurpleMagic/zip/refs/heads/master"
      download_zip "$s5a" "$WORK/packages/ServerS5A3.zip" || download_zip "$s5b" "$WORK/packages/ServerS5A3.zip" || { c_err "ServerS5A3 ZIP 下载失败（$owner）"; return 1; }
      download_zip "$pma" "$WORK/packages/PurpleMagic.zip" || download_zip "$pmb" "$WORK/packages/PurpleMagic.zip" || { c_err "PurpleMagic ZIP 下载失败（$owner）"; return 1; }
    fi
    unpack_archive ServerS5A3 "$WORK/packages/ServerS5A3.zip" AGENTS.md || return 1
    unpack_archive PurpleMagic "$WORK/packages/PurpleMagic.zip" deploy/selfhost/prepare.py || return 1
    SOURCE_KIND=local; save_state
  fi

  if [ "$SOURCE_KIND" = "git" ]; then
    local owner="${REPO_OWNER:-Cec1c}"
    clone_or_pull "https://github.com/$owner/ServerS5A3.git" "$WORK/ServerS5A3" ServerS5A3 AGENTS.md master || \
      clone_or_pull "https://github.com/$owner/ServerS5A3.git" "$WORK/ServerS5A3" ServerS5A3 AGENTS.md main || return 1
    clone_or_pull "https://github.com/$owner/PurpleMagic.git" "$WORK/PurpleMagic" PurpleMagic deploy/selfhost/prepare.py main || \
      clone_or_pull "https://github.com/$owner/PurpleMagic.git" "$WORK/PurpleMagic" PurpleMagic deploy/selfhost/prepare.py master || return 1
  else
    if [ ! -f "$WORK/ServerS5A3/AGENTS.md" ] || [ ! -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ]; then
      echo "请把两份源码上传到服务器："
      echo "  $WORK/ServerS5A3   （含 AGENTS.md、go-server/）"
      echo "  $WORK/PurpleMagic  （含 deploy/selfhost/prepare.py）"
      echo "示例：scp -r ServerS5A3 ubuntu@<服务器IP>:$WORK/"
      echo "或者把离线包放到 $WORK/packages/ 后重新执行第 3 步并选 2"
      while true; do
        if [ -f "$WORK/ServerS5A3/AGENTS.md" ] && [ -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ]; then break; fi
        printf "上传完成后按回车重新检测（输入 q 取消）: "; read -r _a || return 1
        [ "$_a" = "q" ] && return 1
      done
    fi
    [ -f "$WORK/ServerS5A3/AGENTS.md" ] && [ -d "$WORK/ServerS5A3/go-server" ] || { c_err "缺少 $WORK/ServerS5A3（AGENTS.md / go-server）"; return 1; }
    [ -f "$WORK/PurpleMagic/deploy/selfhost/prepare.py" ] || { c_err "缺少 $WORK/PurpleMagic（deploy/selfhost/prepare.py）"; return 1; }
  fi
  [ -d "$WORK/ServerS5A3/.git" ] && echo "ServerS5A3: $(cd "$WORK/ServerS5A3" && git rev-parse --short HEAD)"
  [ -d "$WORK/PurpleMagic/.git" ] && echo "PurpleMagic: $(cd "$WORK/PurpleMagic" && git rev-parse --short HEAD)"
  c_ok "源码就绪"
}

# ---------------------------------------------------------------- 4 地址
fn_address() {
  hr; echo "步骤 4/15：部署方式与地址"
  if [ "${SEQ_MODE:-0}" = 1 ] && [ -n "${DEPLOY_MODE:-}" ] && [ -n "${PUBLIC_IP:-}" ]; then
    echo "当前地址：$DEPLOY_MODE  BIND_IP=$BIND_IP  公网/玩家地址=$PUBLIC_IP  PLAYERS=$PLAYERS_HOST"
    if ask_yes "使用当前地址？" y; then return 0; fi
    DEPLOY_MODE=""; PUBLIC_IP=""; PLAYERS_HOST=""; GM_HOST=""
  elif [ -n "${DEPLOY_MODE:-}" ] && [ -n "${PUBLIC_IP:-}" ]; then
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
  hr; echo "步骤 6/15：可选功能补丁"
  local dir="$SCRIPT_DIR/patches/features"
  if [ -t 0 ] && [ -d "$dir" ]; then
    local previous="${FEATURES:-}" picked="" _f _name _desc _default
    echo "当前已选：${previous:-无}"
    for _f in "$dir"/*/apply.sh; do
      [ -f "$_f" ] || continue
      _name=$(basename "$(dirname "$_f")")
      _desc=$(head -n1 "$(dirname "$_f")/README.md" 2>/dev/null || echo "$_name")
      _default=n
      case " $previous " in *" $_name "*) _default=y ;; esac
      if ask_yes "应用功能补丁 [$_name] $_desc ?" "$_default"; then picked="$picked $_name"; fi
    done
    FEATURES=${picked# }
    save_state
  fi
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
  hr; echo "步骤 8/15：生成服务端运行配置（120 频道 ETC + 官方推荐预设）"
  [ -n "${BIND_IP:-}" ] || { c_err "请先设置部署地址（步骤 4）"; return 1; }
  bootstrap_inputs
  if [ ! -f "$WORK/assets/Script.pvf" ]; then
    c_err "缺少 PVF：$WORK/assets/Script.pvf"
    echo "请把 Script.pvf 上传到 /home/<用户>/DNF90/ 后重跑本步，或直接放到 $WORK/assets/"
    return 1
  fi
  if [ -f "$WORK/ServerS5A3/runtime/docker/data/Script.pvf" ] && \
     ! cmp -s "$WORK/assets/Script.pvf" "$WORK/ServerS5A3/runtime/docker/data/Script.pvf"; then
    echo "-> 检测到 PVF 变化，备份旧运行副本"
    mv "$WORK/ServerS5A3/runtime/docker/data/Script.pvf" \
       "$WORK/ServerS5A3/runtime/docker/data/Script.pvf.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  local od="$WORK/ServerS5A3/runtime/docker/data"
  local ch="$WORK/ServerS5A3/go-server/internal/services/dnfbridge/testdata/channel_info.etc"
  if [ -f "$od/channel.override.etc" ] && ! cmp -s "$od/channel.override.etc" "$ch"; then
    echo "-> 旧外部频道表与新 120 频道基线不同，备份后重新生成"
    mv "$od/channel.override.etc" "$od/channel.override.etc.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  if [ -f "$od/channel_info.etc" ] && ! cmp -s "$od/channel_info.etc" "$ch"; then
    echo "-> 旧内置频道表与新基线不同，备份"
    mv "$od/channel_info.etc" "$od/channel_info.etc.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  # 旧实例迁移：新版不再接受 compat 里的 DNFBRIDGE_BUFF_GROUP_SYNC
  python3 - "$WORK/ServerS5A3/runtime/docker/instance.json" "$WORK/ServerS5A3/deploy/templates/docker-instance.recommended.json" <<'PY'
import json, sys
from pathlib import Path
inst_path, rec_path = Path(sys.argv[1]), Path(sys.argv[2])
if inst_path.is_file():
    c = json.loads(inst_path.read_text(encoding="utf-8"))
    rec = json.loads(rec_path.read_text(encoding="utf-8")) if rec_path.is_file() else {}
    compat = c.setdefault("runtime_compatibility", {})
    compat.pop("DNFBRIDGE_BUFF_GROUP_SYNC", None)
    for k, v in rec.get("runtime_compatibility", {}).items():
        compat.setdefault(k, v)
    for k, v in rec.items():
        if k != "runtime_compatibility":
            c.setdefault(k, v)
    if not c.get("public_host"):
        c["public_host"] = c.get("advertise_ip") or ""
    inst_path.write_text(json.dumps(c, indent=2) + "\n", encoding="utf-8")
PY
  local envprefix="" pubarg="" clientarg=""
  is_rfc1918 "$BIND_IP" || envprefix="env DNF_ALLOW_PUBLIC_HOST=1"
  if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$BIND_IP" ]; then pubarg="--public-host $PUBLIC_IP"; fi
  [ -f "$WORK/assets/DNF.exe" ] && clientarg="--client-dir $WORK/assets"
  sg docker -c "cd $WORK/ServerS5A3 && $envprefix sh deploy/docker/manage.sh prepare --pvf $WORK/assets/Script.pvf --channel-info $ch --host-ip $BIND_IP $pubarg $clientarg" || { c_err "prepare 失败"; return 1; }
  local rec="$WORK/ServerS5A3/deploy/templates/docker-instance.recommended.json"
  local do_preset=${PRESET:-yes}
  if [ "${SEQ_MODE:-0}" = 1 ]; then
    if ask_yes "合并官方推荐玩法预设（Buff/分解/城镇/公会/组队）？" "$([ "$do_preset" = "yes" ] && echo y || echo n)"; then
      do_preset=yes
    else
      do_preset=no
    fi
    PRESET=$do_preset; save_state
  fi
  if [ "$do_preset" = "yes" ] && [ -f "$rec" ]; then
    echo "-> 合并官方推荐预设：${rec#$WORK/ServerS5A3/}"
  elif [ "$do_preset" != "yes" ]; then
    c_warn "已选择不合并推荐预设：大会/Buff/分解/城镇/公会/组队开关保持源码默认（多为关闭）"
  else
    c_warn "未找到 $rec（旧版源码），跳过推荐预设合并"
  fi
  python3 - "$WORK/ServerS5A3/runtime/docker/instance.json" "${PUBLIC_IP:-$BIND_IP}" "$rec" "$do_preset" <<'PY'
import json, secrets, sys
from pathlib import Path
p = Path(sys.argv[1]); pub = sys.argv[2]; recp = Path(sys.argv[3]); do_merge = sys.argv[4] == "yes"
c = json.loads(p.read_text())
if not c.get("player_admin_secret"):
    c["player_admin_secret"] = secrets.token_hex(32)
if not c.get("player_proxy_secret"):
    c["player_proxy_secret"] = secrets.token_hex(32)
if do_merge and recp.is_file():
    rec = json.loads(recp.read_text())
    compat = {**rec.get("runtime_compatibility", {}), **c.get("runtime_compatibility", {})}
    # 新版用 buff_group_sync/tag_buff_group_sync 表达双组 Buff，旧 compat 键会冲突
    compat.pop("DNFBRIDGE_BUFF_GROUP_SYNC", None)
    c = {**rec, **c, "runtime_compatibility": compat}
c.update({
    "joust_event_enabled": False,
    "dungeon_tournament": "vendor",
    "channel_directory_owner_range": "u8",
    "channel_advertise_server": 1,
    "public_bootstrap": True,
    "restart": "unless-stopped",
    "public_host": "" if pub == c["host_ip"] else pub,
    "advertise_ip": "" if pub == c["host_ip"] else pub,
})
p.write_text(json.dumps(c, indent=2) + "\n")
keys = ("host_ip", "advertise_ip", "joust_event_enabled", "dungeon_tournament",
        "buff_group_sync", "buff_swap_reapply", "public_bootstrap")
print("instance.json:", {k: c.get(k) for k in keys})
print("runtime_compatibility keys:", len(c.get("runtime_compatibility", {})))
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
    if [ -f "$WORK/assets/DNF.exe" ]; then
      cp -f "$WORK/assets/DNF.exe" runtime/client-input/DNF.exe
      c_ok "已从 $WORK/assets/DNF.exe 复制客户端 EXE"
    elif _src=$(find_input DNF.exe); then
      cp -f "$_src" runtime/client-input/DNF.exe
      c_ok "已从 $_src 复制客户端 EXE"
    else
      c_err "缺少客户端 EXE（DNF.exe）"
      echo "请把 DNF.exe 上传到 /home/<用户>/DNF90/ 后重跑本步"
      return 1
    fi
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
  python3 - runtime/launcher-input/profile.json <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding='utf-8'))
d['EnableQQBinding'] = True
with open(p, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2); f.write('\n')
print('EnableQQBinding=true（登录器 QQ 绑定入口已开启）')
PY

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
  if [ -n "$(sg docker -c "docker ps -q -f name=purplemagic-gm-1" 2>/dev/null)" ]; then
    echo "-> 重启 gm 以加载新索引"
    sg docker -c "cd $WORK/PurpleMagic && ${C[*]} restart gm" || c_warn "gm 重启失败（可稍后手动 docker compose restart gm）"
  fi
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

  if [ "${SEQ_MODE:-0}" = 1 ]; then
    local qq_script="$WORK/ops/ops-setup-qq-binding.sh"
    [ -f "$qq_script" ] || qq_script="$SCRIPT_DIR/ops-setup-qq-binding.sh"
    if [ -f "$qq_script" ] && ask_yes "是否现在配置 QQ 绑定（可选方案 A/B/C）？" n; then
      bash "$qq_script" || c_warn "QQ 绑定未配置完成；修复后可运行：bash $qq_script"
    fi
  fi
  return 0
}

install_ops() {
  mkdir -p "$WORK/ops"
  local f
  for f in "$SCRIPT_DIR"/ops-*.sh "$SCRIPT_DIR"/update-client-profile.sh; do [ -f "$f" ] && cp -f "$f" "$WORK/ops/"; done
  if [ -d "$SCRIPT_DIR/astrbot-plugin" ]; then
    rm -rf "$WORK/ops/astrbot-plugin"
    cp -r "$SCRIPT_DIR/astrbot-plugin" "$WORK/ops/"
  fi
  find "$WORK/ops" -maxdepth 1 -name '*.sh' -exec sed -i 's/\r$//' {} + 2>/dev/null || true
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
  [ "${SOURCE_KIND:-}" = git ] && src_state="Git: $WORK/ServerS5A3"
  [ "${SOURCE_KIND:-}" = local ] && src_state="本地: $WORK/ServerS5A3"
  local addr_state="未设置"
  [ -n "${DEPLOY_MODE:-}" ] && addr_state="$DEPLOY_MODE  $PUBLIC_IP"
  local feat_state="无"
  [ -n "${FEATURES:-}" ] && feat_state="已选：${FEATURES}"
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
  SEQ_MODE=1
  hr; echo "开始依次执行（过程中会就地询问源码/地址/镜像/功能补丁；任一步失败会停止）"
  local list
  if [ -n "${DNF_ONLY_STEPS:-}" ]; then list="$DNF_ONLY_STEPS"; else list=$(seq 1 "$TOTAL_STEPS"); fi
  local n
  for n in $list; do
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
    echo "  5) 推荐玩法预设（当前：${PRESET:-yes}）"
    echo "  6) 返回"
    local c; c=$(ask "请选择" "6")
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
      5)
        if [ "${PRESET:-yes}" = yes ]; then PRESET=no; else PRESET=yes; fi
        save_state; c_ok "推荐玩法预设：${PRESET}（执行 prepare 时生效）"
        ;;
      6) return 0;;
      *) c_err "无效选择";;
    esac
  done
}

main() {
  ensure_dirs || exit 1
  bootstrap_inputs
  load_state
  while true; do
    print_plan
    echo "直接按回车 = 依次执行 1→15（过程中就地询问必要的选择）；输入编号 = 只执行该步；s = 提前设置（可选）；q = 退出"
    local ch; read -rp "> " ch || exit 0
    case "$ch" in
      "") run_sequence;;
      s|S) settings_menu;;
      q|Q) exit 0;;
      [0-9]|[0-9][0-9]) run_step "$ch" || true;;
      *) c_err "无效输入";;
    esac
    echo
    printf "按回车返回计划..."; read -r _ || exit 0
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
