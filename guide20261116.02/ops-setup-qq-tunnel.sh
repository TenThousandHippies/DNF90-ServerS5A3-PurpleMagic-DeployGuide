#!/bin/bash
# =============================================================================
# ops-setup-qq-tunnel.sh — 在 DNF 服务器上建立到机器人服务器的持久 SSH 反向隧道
#
# 作用：创建 /etc/systemd/system/dnf-qq-tunnel.service，把本机 127.0.0.1:8782
#       映射到远端 127.0.0.1:<远端端口>，开机自启、断线自动重连。
#
# 用法：
#   bash /srv/dnf/ops/ops-setup-qq-tunnel.sh root@152.32.216.181
#   bash /srv/dnf/ops/ops-setup-qq-tunnel.sh --remote root@host --remote-port 18782 --ssh-port 22
# =============================================================================
set -uo pipefail

REMOTE=""
REMOTE_PORT=18782
LOCAL_PORT=8782
SSH_PORT=22
KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
UNIT=/etc/systemd/system/dnf-qq-tunnel.service
SELF=$(readlink -f "$0")

die() { printf '[X] %s\n' "$*" >&2; exit 1; }
ok()  { printf '[OK] %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --remote) REMOTE=${2:-}; shift 2 ;;
    --remote-port) REMOTE_PORT=${2:-}; shift 2 ;;
    --ssh-port) SSH_PORT=${2:-}; shift 2 ;;
    --key) KEY=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,16p' "$SELF"; exit 0 ;;
    *@*) REMOTE=$1; shift ;;
    *) die "未知参数：$1" ;;
  esac
done

[ -n "$REMOTE" ] || die "用法：bash $0 root@152.32.216.181"
[ -f "$KEY" ] || die "找不到私钥 $KEY；先 ssh-keygen 并 ssh-copy-id $REMOTE"
ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$SSH_PORT" -i "$KEY" "$REMOTE" 'echo ok' >/dev/null 2>&1 \
  || die "免密 SSH 失败：检查 ssh-copy-id、端口 $SSH_PORT、私钥 $KEY"

if ! ss -lnt 2>/dev/null | grep -q "127.0.0.1:$LOCAL_PORT"; then
  die "本机 127.0.0.1:$LOCAL_PORT 没有监听，先运行 ops-enable-qq-bot.sh"
fi

sudo -n true 2>/dev/null || die "需要免密 sudo 写 systemd unit"
sudo -n tee "$UNIT" >/dev/null <<EOF
[Unit]
Description=PurpleMagic QQ binding tunnel
After=network-online.target
Wants=network-online.target

[Service]
User=$(id -un)
ExecStart=/usr/bin/ssh -N -p $SSH_PORT -i $KEY -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -R $REMOTE_PORT:127.0.0.1:$LOCAL_PORT $REMOTE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo -n systemctl daemon-reload || die "daemon-reload 失败"
sudo -n systemctl enable --now dnf-qq-tunnel || die "启动 dnf-qq-tunnel 失败"
sleep 2

if systemctl is-active --quiet dnf-qq-tunnel; then
  ok "隧道服务已运行：$REMOTE:$REMOTE_PORT → 127.0.0.1:$LOCAL_PORT"
else
  printf '[!] 服务未运行，查看日志：\n'
  sudo -n journalctl -u dnf-qq-tunnel -n 30 --no-pager
  exit 1
fi

if ssh -o BatchMode=yes -p "$SSH_PORT" -i "$KEY" "$REMOTE" "ss -lnt 2>/dev/null | grep -q '127.0.0.1:$REMOTE_PORT'" 2>/dev/null; then
  ok "远端 127.0.0.1:$REMOTE_PORT 已在监听"
else
  printf '[!] 远端暂未看到 127.0.0.1:%s，稍等几秒或查看 journalctl -u dnf-qq-tunnel\n' "$REMOTE_PORT"
fi

echo
echo "AstrBot 插件填写：endpoint = http://127.0.0.1:$REMOTE_PORT"
echo "查看状态：systemctl status dnf-qq-tunnel --no-pager"
echo "查看日志：journalctl -u dnf-qq-tunnel -n 50 --no-pager"
