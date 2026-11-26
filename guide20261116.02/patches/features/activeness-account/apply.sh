#!/bin/bash
# 可选功能补丁：账号级每日活跃度（同账号所有角色共享进度，奖励只能领一次）
set -euo pipefail
WORK=${1:-/srv/dnf}
SRC="$WORK/ServerS5A3"
[ -d "$SRC" ] || { echo "[X] 找不到 $SRC" >&2; exit 1; }
exec python3 "$(cd "$(dirname "$0")" && pwd)/apply.py" "$SRC" "$@"
