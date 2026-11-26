#!/bin/bash
# =============================================================================
# ops-update-server.sh — 已上线服务器更新服务端源码（保留存档与运行配置）
#
# 做的事：
#   备份数据库/配置 → 给旧镜像打回滚标签 → 换源码（保留 runtime/）→ 重打补丁
#   → 重建镜像 → prepare（120 频道 ETC）→ 合并推荐预设 → 启动 → 自检
#
# 用法：
#   bash /srv/dnf/ops/ops-update-server.sh --latest          # 自动下载最新源码并更新（推荐）
#   bash /srv/dnf/ops/ops-update-server.sh --latest --yes    # 不再确认
#   --mirror official|proxy|auto   下载通道（默认 auto：镜像优先，失败回官方）
#   --proxy https://ghproxy.net    自定义 GitHub 加速前缀
#   bash /srv/dnf/ops/ops-update-server.sh                   # 交互选择方式
#   bash /srv/dnf/ops/ops-update-server.sh --zip /srv/dnf/updates/ServerS5A3.zip
#   bash /srv/dnf/ops/ops-update-server.sh --git
#   可选：--pvf /srv/dnf/assets/Script.pvf  --host-ip 10.0.0.17
#         --channel-info <新源码里的 channel_info.etc>  --no-verify
#
# 默认值：PVF=/srv/dnf/assets/Script.pvf，host-ip 从 runtime/docker/instance.json 读取
# =============================================================================
set -uo pipefail

WORK=${DNF_WORK:-/srv/dnf}
SRC=$WORK/ServerS5A3
PM=$WORK/PurpleMagic
ZIP=""
USE_GIT=0
PVF=$WORK/assets/Script.pvf
HOST_IP=""
CHANNEL=""
VERIFY=1
LATEST=0
OWNER=Cec1c
BRANCH=master
MIRROR=auto
PROXY=""
ASSUME_YES=0
SELF=$(readlink -f "$0")
STAMP=$(date +%Y%m%d-%H%M%S)

die() { printf '[X] %s\n' "$*" >&2; exit 1; }
ok()  { printf '[OK] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --zip) ZIP=${2:-}; shift 2 ;;
    --git) USE_GIT=1; shift ;;
    --latest) LATEST=1; shift ;;
    --owner) OWNER=${2:-}; shift 2 ;;
    --branch) BRANCH=${2:-}; shift 2 ;;
    --mirror) MIRROR=${2:-}; shift 2 ;;
    --proxy) PROXY=${2:-}; MIRROR=proxy; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --pvf) PVF=${2:-}; shift 2 ;;
    --host-ip) HOST_IP=${2:-}; shift 2 ;;
    --channel-info) CHANNEL=${2:-}; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help) sed -n '2,26p' "$SELF"; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[ -d "$SRC" ] || die "找不到 $SRC"
[ -f "$PVF" ] || die "找不到 PVF：$PVF"
[ -f "$SRC/runtime/docker/instance.json" ] || die "缺少 runtime/docker/instance.json（先完成部署）"

if docker info >/dev/null 2>&1; then
  DOCKER="docker"
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER="sudo -n docker"
else
  exec sg docker -c "$(printf '%q ' "$SELF" "$@")"
fi

if [ -z "$HOST_IP" ]; then
  HOST_IP=$(python3 -c "import json;print(json.load(open('$SRC/runtime/docker/instance.json'))['host_ip'])")
fi
[ -n "$CHANNEL" ] || CHANNEL="$SRC/go-server/internal/services/dnfbridge/testdata/channel_info.etc"
[ -f "$CHANNEL" ] || die "找不到频道表：$CHANNEL"

# ---------- 下载工具 ----------
download_to() {
  local url=$1 out=$2
  rm -f "$out"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x 16 -s 16 -k 1M --file-allocation=none --allow-overwrite=true \
      --auto-file-renaming=false -d "$(dirname "$out")" -o "$(basename "$out")" "$url" && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 5 --retry-all-errors --retry-delay 2 --connect-timeout 15 --max-time 900 \
      --progress-bar -C - -o "$out" "$url" && return 0
  fi
  command -v wget >/dev/null 2>&1 && wget -c -O "$out" "$url"
}

zip_ok() { python3 -m zipfile -t "$1" >/dev/null 2>&1; }

source_urls() {
  local owner=$1 branch=$2
  local gh="https://github.com/$owner/ServerS5A3/archive/refs/heads/$branch.zip"
  local official="https://codeload.github.com/$owner/ServerS5A3/zip/refs/heads/$branch"
  case "$MIRROR" in
    official)
      echo "$official" ;;
    proxy)
      if [ -n "$PROXY" ]; then echo "${PROXY%/}/$gh"; else
        for p in https://ghfast.top https://ghproxy.net https://gh-proxy.com; do echo "$p/$gh"; done
      fi ;;
    auto|*)
      if [ -n "$PROXY" ]; then echo "${PROXY%/}/$gh"; else
        for p in https://ghfast.top https://ghproxy.net https://gh-proxy.com; do echo "$p/$gh"; done
      fi
      echo "$official" ;;
  esac
}

# ---------- 选择更新来源 ----------
if [ "$USE_GIT" = 0 ] && [ -z "$ZIP" ] && [ "$LATEST" = 0 ] && [ -t 0 ]; then
  cat <<'EOF'
请选择服务端源码来源：
  1) GitHub 直连下载最新 Cec1c/ServerS5A3
  2) GitHub 加速镜像下载最新 Cec1c/ServerS5A3（推荐国内）
  3) 已有 ZIP 包（从 /srv/dnf/updates 选择）
  4) 当前源码目录 git 更新
  5) 下载 TenThousandHippies/ServerS5A3（加速镜像）
EOF
  read -rp "请输入 1/2/3/4/5 [2]: " pick
  case "${pick:-2}" in
    1) LATEST=1; MIRROR=official ;;
    2) LATEST=1; MIRROR=proxy ;;
    3)
      mkdir -p "$WORK/updates"
      mapfile -t CANDIDATES < <(ls -1t "$WORK"/updates/*.zip 2>/dev/null | head -10)
      if [ ${#CANDIDATES[@]} -gt 0 ]; then
        echo "可用 ZIP："
        i=1
        for f in "${CANDIDATES[@]}"; do echo "  $i) $f ($(du -h "$f" | cut -f1))"; i=$((i+1)); done
        read -rp "输入序号或完整路径: " z
        if [[ "$z" =~ ^[0-9]+$ ]] && [ "$z" -ge 1 ] && [ "$z" -le ${#CANDIDATES[@]} ]; then
          ZIP=${CANDIDATES[$((z-1))]}
        else
          ZIP=$z
        fi
      else
        read -rp "ZIP 路径: " ZIP
      fi
      ;;
    4) USE_GIT=1 ;;
    5) LATEST=1; MIRROR=proxy; OWNER=TenThousandHippies ;;
    *) die "无效选择" ;;
  esac
fi

if [ "$LATEST" = 1 ]; then
  mkdir -p "$WORK/updates" || die "无法创建 $WORK/updates"
  ZIP="$WORK/updates/ServerS5A3-$OWNER-$BRANCH-$(date +%Y%m%d-%H%M%S).zip"
  echo "-> 下载 $OWNER/ServerS5A3 ($BRANCH)，通道：$MIRROR"
  ALT=main; [ "$BRANCH" = main ] && ALT=master
  DOWNLOADED=0
  for b in "$BRANCH" "$ALT"; do
    while IFS= read -r url; do
      echo "-> 尝试：$url"
      if download_to "$url" "$ZIP" && [ -s "$ZIP" ] && zip_ok "$ZIP"; then
        DOWNLOADED=1; break 2
      fi
      warn "该源失败或文件不完整，换下一个"
    done < <(source_urls "$OWNER" "$b")
  done
  [ "$DOWNLOADED" = 1 ] || die "所有下载源都失败；可在 Windows 下载 ZIP 后上传，再用 --zip 指定"
  ok "已下载：$ZIP（$(du -h "$ZIP" | cut -f1)）"
fi

if [ "$USE_GIT" = 0 ] && [ -z "$ZIP" ]; then
  die "没有可用的源码来源（用 --latest / --zip / --git）"
fi
[ -f "$ZIP" ] || die "ZIP 不存在：$ZIP"

if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
  echo
  echo "即将更新服务端：${ZIP:-$SRC (git)}"
  echo "会先备份数据库/运行配置，再重建镜像并重启容器。"
  read -rp "继续？[y/N]: " go
  case "$go" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

echo "== 1/8 备份 =="
if [ -x "$WORK/ops/ops-backup.sh" ]; then
  bash "$WORK/ops/ops-backup.sh" || die "备份失败（先确认数据库容器在运行）"
else
  warn "未找到 $WORK/ops/ops-backup.sh，跳过自动备份；请自行确认已有备份"
fi
cp -a "$SRC/runtime/docker" "$SRC/runtime/docker.bak-update-$STAMP" || die "备份 runtime/docker 失败"
ok "运行配置备份：$SRC/runtime/docker.bak-update-$STAMP"

echo "== 2/8 给旧镜像打回滚标签 =="
$DOCKER tag servers5a3-local:dev "servers5a3-local:rollback-$STAMP" 2>/dev/null \
  && ok "旧镜像：servers5a3-local:rollback-$STAMP" || warn "没有可打标签的旧镜像，跳过"

echo "== 3/8 更新源码（保留 runtime/） =="
if [ "$USE_GIT" = 1 ]; then
  git -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$SRC 不是 git 仓库，改用 --zip"
  git -C "$SRC" fetch --depth 1 origin || die "git fetch 失败"
  git -C "$SRC" reset --hard FETCH_HEAD || die "git reset 失败"
  ok "源码已更新到 $(git -C "$SRC" rev-parse --short HEAD)"
else
  [ -f "$ZIP" ] || die "请用 --zip 指定源码包，或用 --git"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  if command -v unzip >/dev/null 2>&1; then
    unzip -q "$ZIP" -d "$TMP" || die "解压源码包失败"
  else
    python3 -m zipfile -e "$ZIP" "$TMP" || die "解压源码包失败（缺 unzip）"
  fi
  INNER=$(find "$TMP" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$INNER" ] || die "源码包结构异常"
  # 先清空旧源码（保留 runtime/、.git），避免上游删除的 .go 文件残留导致编译失败
  find "$SRC" -mindepth 1 -maxdepth 1 ! -name runtime ! -name .git -exec rm -rf {} + \
    || die "清理旧源码失败"
  tar -C "$INNER" -cf - . | tar -C "$SRC" -xf - || die "覆盖源码失败"
  ok "源码已替换（runtime/ 保留，旧文件已清除）"
fi

echo "== 4/8 重打必要补丁 =="
PATCHER=""
for p in "$WORK/toolkit/patches/apply-local-patches.py" "$WORK/patches/apply-local-patches.py" \
         "$(dirname "$SELF")/patches/apply-local-patches.py" "$(dirname "$SELF")/../toolkit/patches/apply-local-patches.py"; do
  [ -f "$p" ] && PATCHER=$p && break
done
[ -n "$PATCHER" ] || die "找不到 apply-local-patches.py"
python3 "$PATCHER" --server "$SRC" --purplemagic "$PM" || die "补丁失败"
python3 "$PATCHER" --server "$SRC" --purplemagic "$PM" --check | tail -1

# 重新应用 deploy.conf 中选择的可选功能补丁（源码已整体替换，必须重放）
FEATURES=$(grep '^FEATURES=' "$WORK/deploy.conf" 2>/dev/null | cut -d= -f2- || true)
for f in $FEATURES; do
  FEAT_APPLY=""
  for c in "$WORK/toolkit/patches/features/$f/apply.sh" "$(dirname "$SELF")/../patches/features/$f/apply.sh"; do
    [ -f "$c" ] && FEAT_APPLY=$c && break
  done
  if [ -n "$FEAT_APPLY" ]; then
    echo "-> 重新应用可选功能补丁：$f"
    bash "$FEAT_APPLY" "$WORK" || die "可选功能补丁 $f 失败"
  else
    warn "deploy.conf 里选择了功能补丁 $f，但工具包中找不到"
  fi
done

echo "== 5/8 重建服务端镜像 =="
$DOCKER compose version >/dev/null 2>&1 || true
sg docker -c "cd '$SRC' && sh deploy/docker/manage.sh build" || die "镜像构建失败"

echo "== 6/8 prepare =="
# PVF/频道表变化时先备份旧运行副本，避免 prepare 拒绝
if [ -f "$SRC/runtime/docker/data/Script.pvf" ] && ! cmp -s "$PVF" "$SRC/runtime/docker/data/Script.pvf"; then
  mv "$SRC/runtime/docker/data/Script.pvf" "$SRC/runtime/docker/data/Script.pvf.bak-$STAMP"
  ok "旧 PVF 已备份"
fi
if [ -f "$SRC/runtime/docker/data/channel.override.etc" ] && ! cmp -s "$CHANNEL" "$SRC/runtime/docker/data/channel.override.etc"; then
  mv "$SRC/runtime/docker/data/channel.override.etc" "$SRC/runtime/docker/data/channel.override.etc.bak-$STAMP"
  ok "旧频道表已备份"
fi
ENVP=""
case "$HOST_IP" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;; *) ENVP="env DNF_ALLOW_PUBLIC_HOST=1" ;; esac
# 旧实例迁移：新版用 buff_group_sync/tag_buff_group_sync，不再接受 compat 里的旧键
python3 - "$SRC/runtime/docker/instance.json" "$SRC/deploy/templates/docker-instance.recommended.json" <<'PY'
import json, sys
from pathlib import Path
inst_path, rec_path = Path(sys.argv[1]), Path(sys.argv[2])
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
print("instance migrated for 2026-11-24 schema")
PY

PUBLIC_HOST=$(python3 - "$SRC/runtime/docker/instance.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d.get("public_host") or d.get("advertise_ip") or "")
PY
)
PUBARG=""
[ -n "$PUBLIC_HOST" ] && [ "$PUBLIC_HOST" != "$HOST_IP" ] && PUBARG="--public-host $PUBLIC_HOST"
CLIENTARG=""
if [ -f "$PM/runtime/client-input/DNF.exe" ]; then
  CLIENTARG="--client-dir $PM/runtime/client-input"
fi
sg docker -c "cd '$SRC' && $ENVP sh deploy/docker/manage.sh prepare --pvf '$PVF' --channel-info '$CHANNEL' --host-ip '$HOST_IP' $PUBARG $CLIENTARG" \
  || die "prepare 失败（可用 $SRC/runtime/docker.bak-update-$STAMP 回滚）"

echo "== 7/8 合并推荐预设 + 启动 =="
python3 - "$SRC/runtime/docker/instance.json" "$SRC/deploy/templates/docker-instance.recommended.json" "$HOST_IP" <<'PY' || die "合并推荐预设失败"
import json, sys
from pathlib import Path
p, recp, host = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
c = json.loads(p.read_text(encoding="utf-8"))
if recp.is_file():
    rec = json.loads(recp.read_text(encoding="utf-8"))
    compat = {**rec.get("runtime_compatibility", {}), **c.get("runtime_compatibility", {})}
    # 新版改为 buff_group_sync/tag_buff_group_sync，旧 compat 键会触发冲突校验
    compat.pop("DNFBRIDGE_BUFF_GROUP_SYNC", None)
    c = {**rec, **c, "runtime_compatibility": compat}
c["joust_event_enabled"] = False
c["dungeon_tournament"] = "vendor"
c["public_bootstrap"] = True
c["restart"] = "unless-stopped"
c["channel_advertise_server"] = 1
public = c.get("public_host") or c.get("advertise_ip") or ""
c["public_host"] = "" if public == c.get("host_ip") else public
c["advertise_ip"] = c["public_host"]
p.write_text(json.dumps(c, indent=2) + "\n", encoding="utf-8")
PY

sg docker -c "cd '$SRC' && sh deploy/docker/manage.sh up" || die "启动失败（可用 runtime/docker.bak-update-$STAMP 回滚）"

echo "== 8/8 自检 =="
for i in $(seq 1 60); do
  sleep 5
  curl -s --max-time 4 http://127.0.0.1:17002/api/status | grep -q '"ok":true' && break
done
curl -s --max-time 5 http://127.0.0.1:17002/api/status || warn "账号 API 未就绪"
if [ "$VERIFY" = 1 ] && [ -x "$WORK/ops/ops-verify.sh" ]; then
  bash "$WORK/ops/ops-verify.sh" || warn "自检未全部通过，请查看上面的 FAIL 项"
fi

echo
ok "更新完成（源码 $( [ -d "$SRC/.git" ] && git -C "$SRC" rev-parse --short HEAD || echo 'ZIP' )）"
echo "回滚："
echo "  rm -rf $SRC/runtime/docker && cp -a $SRC/runtime/docker.bak-update-$STAMP $SRC/runtime/docker"
echo "  docker tag servers5a3-local:rollback-$STAMP servers5a3-local:dev"
echo "  cd $SRC && sh deploy/docker/manage.sh up"
echo "数据库回滚：使用 /srv/dnf/backups 里本次 ops-backup.sh 生成的 SQL（先停 server 容器再导入）。"
