#!/bin/bash
# =============================================================================
# update-client-profile.sh — 客户端 DNF.exe / Script.pvf 变更后，更新服务端 profile
#
# 做的事：
#   1. 备份旧 DNF.exe / Script.pvf / profile.json / private/player-profile.json
#   2. 复制新文件到 runtime/client-input/
#   3. 重新生成 runtime/launcher-input/profile.json（保留 QQ 绑定开关）
#   4. 停 gateway → 迁移 Hub 发布状态（sequence+1）→ 启 gateway
#   5. 拉 bootstrap 校验新的 ExeSha256 / PvfSha256
#
# 用法：
#   bash /srv/dnf/ops/update-client-profile.sh --exe /path/DNF.exe
#   bash /srv/dnf/ops/update-client-profile.sh --exe /path/DNF.exe --pvf /path/Script.pvf
#   bash /srv/dnf/ops/update-client-profile.sh --help
# =============================================================================
set -uo pipefail

PM=${PM_ROOT:-/srv/dnf/PurpleMagic}
EXE=""
PVF=""
ORIG_ARGS=("$@")
SELF=$(readlink -f "$0")

die() { printf '[X] %s\n' "$*" >&2; exit 1; }
ok()  { printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --exe) EXE=${2:-}; shift 2 ;;
    --pvf) PVF=${2:-}; shift 2 ;;
    --pm)  PM=${2:-}; shift 2 ;;
    -h|--help) sed -n '2,20p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看）" ;;
  esac
done

[ -n "$EXE" ] || die "必须指定 --exe /path/DNF.exe"
[ -f "$EXE" ] || die "找不到 DNF.exe：$EXE"
if [ -n "$PVF" ] && [ ! -f "$PVF" ]; then die "找不到 Script.pvf：$PVF"; fi
[ -d "$PM" ] || die "PurpleMagic 目录不存在：$PM（可用 --pm 指定）"

CLIENT=$PM/runtime/client-input
LAUNCH=$PM/runtime/launcher-input
STAMP=$(date +%Y%m%d-%H%M%S)

for f in "$LAUNCH/server.json" "$LAUNCH/local-tls.pem" "$LAUNCH/local-tls-key.pem" \
         "$LAUNCH/update-public.pem" "$LAUNCH/profile.json" \
         "$CLIENT/DNF.exe" "$CLIENT/Script.pvf" \
         "$PM/scripts/prepare_launcher_profile.py"; do
  [ -f "$f" ] || die "缺少 $f"
done

# docker 权限：直接 / sudo / 用 sg docker 重新执行（保留原始参数）
if docker info >/dev/null 2>&1; then
  DOCKER="docker"
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER="sudo -n docker"
else
  exec sg docker -c "$(printf '%q ' "$SELF" "${ORIG_ARGS[@]}")"
fi

COMPOSE=(compose --env-file "$PM/runtime/selfhost/compose.env" -f "$PM/deploy/selfhost/compose.yaml")

TOOL=""
for p in /srv/dnf/tools/hub-migrate-profile.py "$PM/../tools/hub-migrate-profile.py" \
         "$PM/../toolkit/tools/hub-migrate-profile.py" \
         "$(dirname "$SELF")/../tools/hub-migrate-profile.py" \
         "$(dirname "$SELF")/tools/hub-migrate-profile.py"; do
  [ -f "$p" ] && TOOL=$p && break
done
[ -n "$TOOL" ] || die "找不到 hub-migrate-profile.py（从工具包复制到 /srv/dnf/tools/）"

cd "$PM" || die "无法进入 $PM"

echo "== 1/5 备份旧文件 =="
cp -f "$CLIENT/DNF.exe" "$CLIENT/DNF.exe.bak-$STAMP"
cp -f "$CLIENT/Script.pvf" "$CLIENT/Script.pvf.bak-$STAMP"
cp -f "$LAUNCH/profile.json" "$LAUNCH/profile-$STAMP.json"
OLD_PROFILE="$LAUNCH/profile-$STAMP.json"
if [ -f runtime/selfhost/private/player-profile.json ]; then
  cp -f runtime/selfhost/private/player-profile.json "runtime/selfhost/private/player-profile.json.bak-$STAMP"
fi
ok "备份完成（$STAMP）"

echo "== 2/5 复制新客户端文件 =="
cp -f "$EXE" "$CLIENT/DNF.exe"
[ -n "$PVF" ] && cp -f "$PVF" "$CLIENT/Script.pvf"
ok "DNF.exe $(sha256sum "$CLIENT/DNF.exe" | cut -d' ' -f1)"
[ -n "$PVF" ] && ok "Script.pvf $(sha256sum "$CLIENT/Script.pvf" | cut -d' ' -f1)"

echo "== 3/5 重新生成 profile =="
rm -f "$LAUNCH/profile.json"
python3 scripts/prepare_launcher_profile.py \
  --connection "$LAUNCH/server.json" \
  --client "$CLIENT" \
  --certificate "$LAUNCH/local-tls.pem" \
  --public-key "$LAUNCH/update-public.pem" \
  --output "$LAUNCH/profile.json" || die "profile 生成失败"

python3 - "$OLD_PROFILE" "$LAUNCH/profile.json" <<'PY' || die "profile 开关处理失败"
import json, sys
old = json.load(open(sys.argv[1], encoding="utf-8"))
new = json.load(open(sys.argv[2], encoding="utf-8"))
for key in ("EnableQQBinding", "RequireQQBinding"):
    if key in old:
        new[key] = old[key]
new.setdefault("EnableQQBinding", True)
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(new, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("EnableQQBinding=%s RequireQQBinding=%s" % (
    new.get("EnableQQBinding"), new.get("RequireQQBinding")))
PY
ok "profile 已更新"

echo "== 4/5 迁移 Hub 发布状态 =="
$DOCKER "${COMPOSE[@]}" stop gateway >/dev/null 2>&1 || true
python3 "$TOOL" --selfhost runtime/selfhost --profile "$LAUNCH/profile.json" || die "Hub 迁移失败"
if ! python3 - runtime/selfhost/hub/state.json "$LAUNCH/profile.json" <<'PY'
import json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))["published"]
new = json.load(open(sys.argv[2], encoding="utf-8"))
for key in ("ExeSha256", "PvfSha256"):
    a = str(st.get("profile", {}).get(key, "")).lower()
    b = str(new.get(key, "")).lower()
    if a != b:
        print("[X] published %s=%s, expected %s" % (key, a, b))
        sys.exit(1)
print("[OK] published profile matches, sequence", st.get("sequence"))
PY
then
  $DOCKER "${COMPOSE[@]}" up -d gateway >/dev/null 2>&1 || true
  die "Hub 发布状态未更新（见上面 published 哈希）；gateway 已按旧状态启动"
fi
$DOCKER "${COMPOSE[@]}" up -d gateway >/dev/null || die "gateway 启动失败"

echo "== 5/5 校验 bootstrap =="
CA=$PM/runtime/selfhost/tls-player/ca.pem
API=$(python3 -c "import json;print(json.load(open('$LAUNCH/profile.json'))['ApiUrl'])")
EXE_HASH=$(sha256sum "$CLIENT/DNF.exe" | cut -d' ' -f1)
PVF_HASH=$(sha256sum "$CLIENT/Script.pvf" | cut -d' ' -f1)
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for i in $(seq 1 30); do
  sleep 2
  curl -s --max-time 6 --cacert "$CA" -o "$TMP" "$API/launcher/v2/bootstrap.json" 2>/dev/null || true
  [ -s "$TMP" ] && break
done
[ -s "$TMP" ] || {
  warn "无法获取 bootstrap（$API），gateway 日志："
  $DOCKER "${COMPOSE[@]}" logs --tail 50 gateway
  die "校验失败"
}

python3 - "$EXE_HASH" "$PVF_HASH" "$TMP" <<'PY'
import base64, json, sys
want_exe, want_pvf, path = sys.argv[1], sys.argv[2], sys.argv[3]
env = json.load(open(path, encoding="utf-8"))
p = json.loads(base64.b64decode(env["Payload"]))
prof = p["profile"]
print("sequence:", p.get("sequence"))
print("ExeSha256:", prof.get("ExeSha256"), "expected:", want_exe)
print("PvfSha256:", prof.get("PvfSha256"), "expected:", want_pvf)
ok_exe = str(prof.get("ExeSha256", "")).lower() == want_exe.lower()
ok_pvf = str(prof.get("PvfSha256", "")).lower() == want_pvf.lower()
print("[%s] ExeSha256" % ("PASS" if ok_exe else "FAIL"))
print("[%s] PvfSha256" % ("PASS" if ok_pvf else "FAIL"))
sys.exit(0 if ok_exe and ok_pvf else 1)
PY
RESULT=$?
[ "$RESULT" = 0 ] || die "bootstrap 哈希不一致；备份在 $CLIENT/*.bak-$STAMP 和 $LAUNCH/profile-$STAMP.json"

ok "完成：客户端重启登录器即可拉到新 profile（无需重编登录器）"
echo "回滚："
echo "  cp $CLIENT/DNF.exe.bak-$STAMP $CLIENT/DNF.exe"
echo "  cp $CLIENT/Script.pvf.bak-$STAMP $CLIENT/Script.pvf"
echo "  cp $LAUNCH/profile-$STAMP.json $LAUNCH/profile.json"
echo "  python3 $TOOL --selfhost runtime/selfhost --profile $LAUNCH/profile.json"
echo "  $DOCKER ${COMPOSE[*]} up -d gateway"
