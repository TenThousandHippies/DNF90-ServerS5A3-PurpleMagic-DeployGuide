#!/bin/bash
# =============================================================================
# ops-setup-qq-binding.sh — 一键配置 QQ 绑定（会先让你选方案）
#
# 方案 A：复用现有 AstrBot + NapCat（另一台机器）
#         开启 DNF 网关回环接口 → 建 SSH 反向隧道 → 复制 AstrBot 插件
# 方案 B：在 DNF 服务器运行官方 QQ Agent（需要 Node.js + OneBot）
#         开启本机接口 → 准备 qq-agent → 复制官方插件 → 提示 OneBot/启动步骤
# 方案 C：只开本机 127.0.0.1:8782（机器人已同机或自己接）
# 不配置：跳过，不修改任何配置（不启用 QQ 绑定）
#
# 用法：
#   bash /srv/dnf/ops/ops-setup-qq-binding.sh                    # 交互选择
#   bash /srv/dnf/ops/ops-setup-qq-binding.sh --mode a --remote root@152.32.216.181
#   bash /srv/dnf/ops/ops-setup-qq-binding.sh --mode b
#   bash /srv/dnf/ops/ops-setup-qq-binding.sh --mode c
#   bash /srv/dnf/ops/ops-setup-qq-binding.sh --mode skip   # 不配置 QQ 绑定
# =============================================================================
set -uo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
PM=${PM_ROOT:-/srv/dnf/PurpleMagic}
MODE=""
REMOTE=""
REMOTE_PORT=18782
SSH_PORT=22
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
ASTRBOT_DIR=/root/astrbot/data
QQAGENT_DIR=/opt/qq-agent
ASSUME_YES=0
SELF=$(readlink -f "$0")

die() { printf '[X] %s\n' "$*" >&2; exit 1; }
ok()  { printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE=${2:-}; shift 2 ;;
    --remote) REMOTE=${2:-}; shift 2 ;;
    --remote-port) REMOTE_PORT=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    --astrbot-dir) ASTRBOT_DIR=${2:-}; shift 2 ;;
    --qqagent-dir) QQAGENT_DIR=${2:-}; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --local-only) MODE=c; shift ;;
    -h|--help) sed -n '2,22p' "$SELF"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [ -z "$MODE" ]; then
  cat <<'EOF'
请选择 QQ 绑定方案：
  1) 方案 A：复用现有 AstrBot + NapCat（机器人在另一台服务器）
  2) 方案 B：在 DNF 服务器运行官方 QQ Agent（需要 Node.js + OneBot）
  3) 方案 C：只开本机接口 127.0.0.1:8782
  4) 不配置：跳过，不启用 QQ 绑定（不影响普通登录/改密）
EOF
  read -rp "请输入 1/2/3/4 [1]: " pick
  case "${pick:-1}" in
    1) MODE=a ;;
    2) MODE=b ;;
    3) MODE=c ;;
    4) MODE=skip ;;
    *) die "无效选择" ;;
  esac
fi

case "$MODE" in a|b|c|skip) ;; *) die "MODE 只能是 a/b/c/skip" ;; esac

if [ "$MODE" = "skip" ]; then
  echo "已跳过：未修改 gateway.json，未建立隧道，未安装任何机器人插件。"
  echo "玩家仍可正常注册/登录/改密；登录器建议把 EnableQQBinding 设为 false。"
  exit 0
fi

[ -x "$DIR/ops-enable-qq-bot.sh" ] || die "缺少 $DIR/ops-enable-qq-bot.sh"

echo "== 1/3 开启网关 QQ 接口 =="
bash "$DIR/ops-enable-qq-bot.sh" || die "开启网关 QQ 接口失败"

TOKEN=$(python3 - "$PM/runtime/selfhost/gateway.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("qq_bot_token", ""))
PY
) || die "读取 qq_bot_token 失败"
[ ${#TOKEN} -ge 32 ] || die "qq_bot_token 无效"

ENDPOINT="http://127.0.0.1:8782"

if [ "$MODE" = "a" ]; then
  if [ -z "$REMOTE" ]; then
    read -rp "机器人服务器 SSH（如 root@152.32.216.181）: " REMOTE
  fi
  [ -n "$REMOTE" ] || die "方案 A 需要机器人服务器 SSH"

  ssh_ok() { ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" -i "$KEY" "$REMOTE" 'echo ok' >/dev/null 2>&1; }

  if [ ! -f "$KEY" ]; then
    mkdir -p "$(dirname "$KEY")"
    ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null 2>&1 || die "生成 SSH 密钥失败：$KEY"
    ok "已生成 SSH 密钥：$KEY"
  fi

  if ! ssh_ok; then
    echo "需要把公钥复制到 $REMOTE（会提示输入一次该服务器密码）"
    DO_COPY=0
    if [ "$ASSUME_YES" = 1 ]; then
      DO_COPY=1
    elif [ -t 0 ]; then
      read -rp "现在执行 ssh-copy-id？[Y/n]: " ans
      [ -z "$ans" ] || [ "$ans" = y ] || [ "$ans" = Y ] && DO_COPY=1
    fi
    if [ "$DO_COPY" = 1 ]; then
      ssh-copy-id -i "$KEY.pub" -p "$SSH_PORT" "$REMOTE" || true
    fi
    if ! ssh_ok; then
      printf '[X] 免密 SSH 仍未配置。请在 DNF 服务器手动执行：\n'
      printf '    ssh-copy-id -i %s.pub -p %s %s\n' "$KEY" "$SSH_PORT" "$REMOTE"
      printf '然后重跑：bash %s --mode a --remote %s\n' "$SELF" "$REMOTE"
      exit 1
    fi
    ok "免密 SSH 已配置"
  fi

  echo "== 2/3 建立持久隧道 =="
  bash "$DIR/ops-setup-qq-tunnel.sh" --remote "$REMOTE" --remote-port "$REMOTE_PORT" \
    --ssh-port "$SSH_PORT" --key "$KEY" || die "隧道配置失败"
  ENDPOINT="http://127.0.0.1:$REMOTE_PORT"

  echo "== 3/3 复制 AstrBot 插件 =="
  SRC=""
  for c in "$DIR/astrbot-plugin/purplemagic-binding" "$DIR/../toolkit/astrbot-plugin/purplemagic-binding" \
           "$PM/../toolkit/astrbot-plugin/purplemagic-binding" "$PM/../astrbot-plugin/purplemagic-binding"; do
    [ -d "$c" ] && SRC=$c && break
  done
  if [ -n "$SRC" ] && [ -d "$SRC" ]; then
    ssh -o BatchMode=yes -p "$SSH_PORT" -i "$KEY" "$REMOTE" "mkdir -p '$ASTRBOT_DIR/plugins'" || die "创建远端插件目录失败"
    scp -q -r -P "$SSH_PORT" -i "$KEY" "$SRC" "$REMOTE:$ASTRBOT_DIR/plugins/" || die "复制插件失败"
    ok "已复制到 $REMOTE:$ASTRBOT_DIR/plugins/purplemagic-binding"
    CONTAINER=$(ssh -o BatchMode=yes -p "$SSH_PORT" -i "$KEY" "$REMOTE" \
      "docker ps --format '{{.Names}}' | grep -i astrbot | head -1" 2>/dev/null || true)
    if [ -n "$CONTAINER" ]; then
      ssh -o BatchMode=yes -p "$SSH_PORT" -i "$KEY" "$REMOTE" "docker restart '$CONTAINER'" >/dev/null \
        && ok "已重启 AstrBot 容器：$CONTAINER"
    else
      warn "未检测到 astrbot 容器，请手动重启 AstrBot"
    fi
  else
    warn "工具包里没有 astrbot-plugin/purplemagic-binding，跳过插件复制"
  fi

  cat <<EOF

下一步（AstrBot 页面）：
  1. 打开「插件」→「PurpleMagic 账号绑定」
  2. endpoint 填：$ENDPOINT
  3. token 填：$TOKEN
  4. 启用插件
  5. 确认 NapCat 已连接、机器人在允许群内

EOF

elif [ "$MODE" = "b" ]; then
  echo "== 2/3 准备 QQ Agent =="
  if ! command -v node >/dev/null 2>&1; then
    warn "未安装 Node.js（QQ Agent 需要 20+）"
    cat <<'EOF'
请先安装 Node.js，例如：
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
或使用 nvm。装好后重新执行本脚本 --mode b。
EOF
    exit 1
  fi
  ok "Node.js $(node -v)"

  if [ ! -d "$QQAGENT_DIR" ]; then
    if [ "$ASSUME_YES" = 1 ] || { read -rp "未找到 $QQAGENT_DIR，是否现在 git clone QQ Agent？[y/N]: " a; [ "$a" = y ]; }; then
      git clone https://github.com/Kondius/qq-agent.git "$QQAGENT_DIR" || die "git clone 失败（检查网络）"
      (cd "$QQAGENT_DIR" && npm install) || die "npm install 失败"
    else
      warn "已跳过 QQ Agent 安装；装好后重跑本脚本 --mode b"
      exit 1
    fi
  fi

  echo "== 3/3 安装官方绑定插件 =="
  SRC="$PM/integrations/qq-agent/plugins/purplemagic-binding"
  [ -d "$SRC" ] || SRC="$DIR/integrations/qq-agent/plugins/purplemagic-binding"
  [ -d "$SRC" ] || die "找不到官方插件目录 integrations/qq-agent/plugins/purplemagic-binding"
  mkdir -p "$QQAGENT_DIR/plugins"
  rm -rf "$QQAGENT_DIR/plugins/purplemagic-binding"
  cp -r "$SRC" "$QQAGENT_DIR/plugins/"
  python3 "$PM/integrations/qq-agent/install_adapter.py" "$QQAGENT_DIR" \
    || python3 "$DIR/integrations/qq-agent/install_adapter.py" "$QQAGENT_DIR" \
    || die "安装 QQ Agent 适配失败"
  ok "官方插件与适配已安装到 $QQAGENT_DIR"

  cat <<EOF

下一步（QQ Agent）：
  1. 配置 OneBot（NapCat/Lagrange）连接，登录机器人 QQ；
  2. 打开「插件 → PurpleMagic 账号绑定」，填：
       endpoint: http://127.0.0.1:8782
       token   : $TOKEN
  3. 启动 QQ Agent（按其 README，通常是 npm start）
  4. 机器人加入 GM 配置的允许群

EOF

else
  echo "== 2/3 仅开启本机接口 =="
  ok "只开启 127.0.0.1:8782（未建隧道、未装插件）"
fi

echo
ok "QQ 绑定接口已就绪"
echo "  endpoint: $ENDPOINT"
echo "  token   : $TOKEN"
echo
echo "最后别忘了：GM → 反作弊 → 账号与 QQ 号 → 添加允许群并选择绑定方式。"
echo "机器人服务器换 IP：重跑本脚本，方案 A 传新的 --remote 即可（Token 不变）。"
