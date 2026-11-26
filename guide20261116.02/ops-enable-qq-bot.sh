#!/bin/bash
# =============================================================================
# ops-enable-qq-bot.sh — 开启 PlayerGateway 的 QQ 绑定回环接口
#
# 作用：在 /srv/dnf/PurpleMagic/runtime/selfhost/gateway.json 写入
#   qq_bot_listen = 127.0.0.1:8782
#   qq_bot_token  = 随机 64 位十六进制（>=32 字符）
# 然后重启 gateway，并打印供 QQ Agent 插件填写的 Token。
#
# 用法：
#   bash /srv/dnf/ops/ops-enable-qq-bot.sh
#   QQ_BOT_TOKEN=xxxx bash /srv/dnf/ops/ops-enable-qq-bot.sh   # 指定 Token
# =============================================================================
set -uo pipefail

PM=${PM_ROOT:-/srv/dnf/PurpleMagic}
GW=$PM/runtime/selfhost/gateway.json
SELF=$(readlink -f "$0")

die() { printf '[X] %s\n' "$*" >&2; exit 1; }
ok()  { printf '[OK] %s\n' "$*"; }

[ -f "$GW" ] || die "缺少 $GW（先完成部署）"

if docker info >/dev/null 2>&1; then
  DOCKER="docker"
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER="sudo -n docker"
else
  exec sg docker -c "$(printf '%q ' "$SELF" "$@")"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
cp -f "$GW" "$GW.bak-$STAMP" || die "备份 $GW 失败"

EXISTING_TOKEN=$(python3 - "$GW" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("qq_bot_token", ""))
except Exception:
    print("")
PY
)
TOKEN=${QQ_BOT_TOKEN:-$EXISTING_TOKEN}
if [ ${#TOKEN} -lt 32 ]; then
  TOKEN=$(openssl rand -hex 32)
  echo "-> 生成新的 qq_bot_token"
else
  echo "-> 复用现有 qq_bot_token（换机器人 IP 不会改变插件配置）"
fi
[ ${#TOKEN} -ge 32 ] || die "QQ_BOT_TOKEN 至少 32 个字符"

python3 - "$GW" "$TOKEN" <<'PY' || die "写入 gateway.json 失败"
import json, sys
path, token = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    cfg = json.load(f)
cfg["qq_bot_listen"] = "127.0.0.1:8782"
cfg["qq_bot_token"] = token
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("gateway.json updated")
PY

ok "已写入 qq_bot_listen=127.0.0.1:8782"

cd "$PM" || die "无法进入 $PM"
# 配置内容变了但容器规格没变，up -d 不会重启；必须 force-recreate
$DOCKER compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml up -d --force-recreate gateway >/dev/null \
  || die "gateway 重启失败"

for i in $(seq 1 15); do
  sleep 1
  ss -lnt 2>/dev/null | grep -q '127.0.0.1:8782' && break
done
if ss -lnt 2>/dev/null | grep -q '127.0.0.1:8782'; then
  ok "8782 端口已监听"
else
  printf '[!] 未检测到 127.0.0.1:8782，检查 gateway 日志：\n'
  $DOCKER compose --env-file runtime/selfhost/compose.env -f deploy/selfhost/compose.yaml logs --tail 30 gateway
fi

echo
echo "把下面两项填到 QQ Agent 插件「PurpleMagic 账号绑定」："
echo "  endpoint: http://127.0.0.1:8782"
echo "  token   : $TOKEN"
echo
echo "备份：$GW.bak-$STAMP"
echo "注意：以后重新执行 prepare.py 会覆盖 gateway.json，需要重新运行本脚本。"
