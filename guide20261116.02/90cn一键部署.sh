#!/bin/bash
# =============================================================================
# 90cn 一键部署 — 上传检查 + 目录初始化 + 解压工具包 + 进入交互部署
#
# 用法：
#   1) 先把 DNF.exe、Script.pvf、DNF90-部署工具包.zip 上传到 /home/<用户>/DNF90/
#      （例如 /home/ubuntu/DNF90/），然后（脚本可从任意目录运行）：
#        bash /home/ubuntu/90cn一键部署.sh
#   2) 文件不齐时脚本会给出上传命令并退出，补传后重新执行即可。
# =============================================================================
set -uo pipefail

WORK=${DNF_WORK:-/srv/dnf}
HOME_DIR=${DNF_HOME:-$HOME/DNF90}
mkdir -p "$HOME_DIR" 2>/dev/null || true
PKG=DNF90-部署工具包.zip
FILES=(DNF.exe Script.pvf "$PKG")
missing=0

echo "== 检查上传文件（$HOME_DIR） =="
for f in "${FILES[@]}"; do
  if [ -f "$HOME_DIR/$f" ]; then
    printf '  [OK] %s (%s)\n' "$HOME_DIR/$f" "$(du -h "$HOME_DIR/$f" | cut -f1)"
  else
    printf '  [MISS] %s\n' "$HOME_DIR/$f"; missing=1
  fi
done

if [ "$missing" = 1 ]; then
  cat <<EOF

请先把以下 3 个文件上传到：$HOME_DIR
  - DNF.exe                  （游戏客户端主程序）
  - Script.pvf               （客户端 PVF）
  - $PKG      （部署工具包）

在你自己的电脑上执行（PowerShell / cmd）：
  scp DNF.exe Script.pvf $PKG ${USER:-$(id -un)}@<服务器IP>:$HOME_DIR/

上传完成后重新执行：
  bash "$HOME_DIR/90cn一键部署.sh"
EOF
  exit 1
fi

echo "== 创建目录 =="
DIRS=(assets logs backups ops packages probe)
if mkdir -p "${DIRS[@]/#/$WORK/}" 2>/dev/null; then
  echo "  [OK] $WORK/{assets,logs,backups,ops,packages,probe}"
else
  sudo -n mkdir -p "${DIRS[@]/#/$WORK/}" || { echo "  [FAIL] 无法创建 $WORK 目录（需要 sudo）"; exit 1; }
  sudo -n chown -R "$(id -u):$(id -g)" "$WORK" || true
  echo "  [OK] 已用 sudo 创建并授权"
fi

echo "== 放置文件 =="
cp -f "$HOME_DIR/DNF.exe" "$WORK/assets/DNF.exe"
cp -f "$HOME_DIR/Script.pvf" "$WORK/assets/Script.pvf"
cp -f "$HOME_DIR/$PKG" "$WORK/$PKG"
echo "  [OK] DNF.exe / Script.pvf → $WORK/assets/"

if ! command -v unzip >/dev/null 2>&1; then
  echo "  安装 unzip"
  sudo -n apt-get install -y -qq unzip >/dev/null 2>&1 || { echo "  [FAIL] 缺少 unzip，请先 sudo apt-get install -y unzip"; exit 1; }
fi

echo "== 解压工具包 =="
rm -rf "$WORK/toolkit"
mkdir -p "$WORK/toolkit"
python3 - "$WORK/$PKG" "$WORK/toolkit" <<'PY' || { echo "  [FAIL] 解压失败：$WORK/$PKG"; exit 1; }
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
[ -f "$WORK/toolkit/deploy-oneclick.sh" ] || { echo "  [FAIL] 工具包里没有 deploy-oneclick.sh"; exit 1; }
# 工具包在 Windows 打包时可能带 CRLF，统一成 LF，避免 bash 报 $'\r'
find "$WORK/toolkit" -maxdepth 2 \( -name '*.sh' -o -name '*.py' \) -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$WORK"/toolkit/*.sh 2>/dev/null || true
echo "  [OK] $WORK/toolkit"

cd "$WORK/toolkit" || exit 1
exec bash deploy-oneclick.sh
