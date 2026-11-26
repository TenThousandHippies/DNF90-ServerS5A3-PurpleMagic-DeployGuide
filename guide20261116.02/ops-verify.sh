#!/bin/bash
# 一键自检：容器、账号 API、频道端口、活动开关、网关与频道握手
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# docker 权限：直接 / sudo / 都没有
if docker info >/dev/null 2>&1; then
  DK=(docker)
elif sudo -n docker info >/dev/null 2>&1; then
  DK=(sudo -n docker)
else
  echo "  [FAIL] 无法访问 Docker（需要 docker 组或免密 sudo）"
  echo; echo "结果：PASS=0 FAIL=1"; echo "VERIFY_FAILED"; exit 1
fi

echo "== 1. 容器 =="
PS=$("${DK[@]}" ps -a --format '{{.Names}}|{{.Label "com.docker.compose.service"}}|{{.State}}' 2>/dev/null)
svc_name()  { echo "$PS" | awk -F'|' -v s="$1" '$2==s{print $1; exit}'; }
exact_name() { # 兼容没有 compose 标签的手工容器
  case "$1" in
    db) echo servers5a3-local-db-1;; server) echo servers5a3-local-server-1;;
    gateway) echo purplemagic-gateway-1;; gm) echo purplemagic-gm-1;; edge) echo purplemagic-edge-1;;
  esac
}
check_svc() {
  local svc=$1 name health state
  name=$(svc_name "$svc"); [ -n "$name" ] || name=$(exact_name "$svc")
  if ! "${DK[@]}" inspect "$name" >/dev/null 2>&1; then bad "$svc = missing"; return; fi
  if [ "$svc" = db ] || [ "$svc" = server ]; then
    health=$("${DK[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)
    [ "$health" = healthy ] && ok "$name healthy" || bad "$name = ${health:-unknown}"
  else
    state=$("${DK[@]}" inspect -f '{{.State.Status}}' "$name" 2>/dev/null)
    [ "$state" = running ] && ok "$name running" || bad "$name = ${state:-unknown}"
  fi
}
for s in db server gateway gm edge; do check_svc "$s"; done

echo "== 2. 账号 API =="
curl -s --max-time 5 http://127.0.0.1:17002/api/status | grep -q '"ok":true' && ok "17002 /api/status" || bad "17002 /api/status"

echo "== 3. 频道端口 =="
HOST_IP=$(python3 -c "import json;print(json.load(open('/srv/dnf/ServerS5A3/runtime/docker/instance.json'))['host_ip'])" 2>/dev/null)
n=$(ss -lnt | grep -c "$HOST_IP:10")
[ "$n" -eq 120 ] && ok "120 个频道端口监听（$HOST_IP）" || bad "频道端口数=$n（$HOST_IP）"
ss -lnt | grep -q "$HOST_IP:7001" && ok "7001 引导端口（$HOST_IP）" || bad "7001 未监听（$HOST_IP）"

echo "== 4. 活动 2365 =="
SECRET=$(python3 -c "import json;print(json.load(open('/srv/dnf/ServerS5A3/runtime/docker/instance.json'))['player_admin_secret'])" 2>/dev/null)
if curl -s --max-time 8 -X POST http://127.0.0.1:17002/api/game/admin \
     -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
     -d '{"version":1,"action":"activities"}' > /tmp/verify-act.json 2>/dev/null && \
   python3 - <<'PY'
import json, sys
try:
    d = json.load(open('/tmp/verify-act.json'))
    a = {x['id']: x for x in d['activities']['activities']}
    x = a.get(2365, {})
    good = x.get('enabled') is False and x.get('effectiveEnabled') is False
    print('  [%s] 2365 enabled=%s effective=%s pendingRestart=%s' % (
        'PASS' if good else 'FAIL', x.get('enabled'), x.get('effectiveEnabled'), x.get('pendingRestart')))
    sys.exit(0 if good else 1)
except Exception as e:
    print('  [FAIL] 2365 查询失败：%s' % e); sys.exit(1)
PY
then ok "2365 关闭"; else bad "2365 未关闭或查询失败"; fi

echo "== 5. 玩家网关 =="
CA=/srv/dnf/PurpleMagic/runtime/selfhost/tls-player/ca.pem
PM_URL=$(python3 -c "import json;print(json.load(open('/srv/dnf/PurpleMagic/runtime/launcher-input/profile.json'))['ApiUrl'])" 2>/dev/null)
if [ -n "$PM_URL" ] && [ -f "$CA" ]; then
  curl -s --max-time 8 --cacert "$CA" "$PM_URL/api/status" | grep -q '"ok":true' \
    && ok "$PM_URL /api/status（证书固定链）" || bad "$PM_URL /api/status"
  code=$(curl -s --max-time 8 --cacert "$CA" -o /dev/null -w '%{http_code}' "$PM_URL/launcher/v2/bootstrap.json")
  [ "$code" = "200" ] && ok "bootstrap.json 200" || bad "bootstrap.json=$code"
else
  bad "缺少 profile.json 或 CA（网关尚未生成）"
fi

echo "== 6. 频道握手（探测器） =="
if [ -x /usr/bin/dotnet ] && [ -f /srv/dnf/probe/Launcher.Probe.dll ]; then
  if dotnet /srv/dnf/probe/Launcher.Probe.dll /srv/dnf/probe/profile.json --channel-only 2>&1 | tee /tmp/verify-probe.log | grep -q 'PASS native channel bootstrap'; then
    ok "$(grep 'PASS native' /tmp/verify-probe.log)"
  else
    bad "频道握手失败：$(tail -2 /tmp/verify-probe.log | tr '\n' ' ')"
  fi
else
  echo "  [SKIP] 无 dotnet 或探测器"
fi

echo
echo "结果：PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "VERIFY_OK" || echo "VERIFY_FAILED"
