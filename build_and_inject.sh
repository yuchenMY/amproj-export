#!/usr/bin/env bash
# build_and_inject.sh — 一键: 推 CI 构建 MeowRotate3D.dylib → 下载产物 → 注入 r19 IPA 出测试包
# 用法: bash build_and_inject.sh   (前提: 本地代理 7890 已开, git 已配 github 凭据)
set -e
cd "$(dirname "$0")"

REPO="yuchenMY/amproj-export"   # 借用现有仓库的分支触发 CI
BRANCH="meow3d"
TOKEN_FILE="/tmp/gh_token.txt"

echo "== [1/6] 读取 git 凭据 (不回显) =="
printf "protocol=https\nhost=github.com\n" | git credential fill 2>/dev/null | grep password= | cut -d= -f2 > "$TOKEN_FILE"
[ -s "$TOKEN_FILE" ] || { echo "没有 github 凭据"; exit 1; }
TOKEN=$(cat "$TOKEN_FILE")
GH_AUTH=$(printf "%s" "$TOKEN" | python -c "import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read().strip()))")
USER=$(printf "protocol=https\nhost=github.com\n" | git credential fill 2>/dev/null | grep username= | cut -d= -f2)

export HTTPS_PROXY=http://127.0.0.1:7890 HTTP_PROXY=http://127.0.0.1:7890

echo "== [2/6] 推送 gh_build 到分支 $BRANCH =="
git remote remove ci 2>/dev/null || true
git remote add ci "https://github.com/$REPO.git"
git push ci "HEAD:refs/heads/$BRANCH" --force

echo "== [3/6] 等待 Actions 运行完成 =="
RUN_ID=""
for i in $(seq 1 60); do
  sleep 15
  RESP=$(curl -s -H "Authorization: token $TOKEN" "https://api.github.com/repos/$REPO/actions/runs?branch=$BRANCH&per_page=1")
  RUN_ID=$(echo "$RESP" | python -c "import sys,json;d=json.load(sys.stdin);r=d.get('workflow_runs') or [];print(r[0]['id'] if r else '')")
  STATUS=$(echo "$RESP" | python -c "import sys,json;d=json.load(sys.stdin);r=d.get('workflow_runs') or [];print(r[0]['status'] if r else '')")
  CONCL=$(echo "$RESP" | python -c "import sys,json;d=json.load(sys.stdin);r=d.get('workflow_runs') or [];print(r[0].get('conclusion') if r else '')")
  echo "  poll#$i run=$RUN_ID status=$STATUS concl=$CONCL"
  [ "$STATUS" = "completed" ] && break
done
[ "$CONCL" = "success" ] || { echo "CI 失败, 结束"; exit 1; }

echo "== [4/6] 下载产物 =="
ART_URL="https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts"
ART_ID=$(curl -s -H "Authorization: token $TOKEN" "$ART_URL" | python -c "import sys,json;a=json.load(sys.stdin).get('artifacts') or [];print(a[0]['id'] if a else '')")
[ -n "$ART_ID" ] || { echo "无产物"; exit 1; }
curl -sL -H "Authorization: token $TOKEN" -o dylibs.zip "https://api.github.com/repos/$REPO/actions/artifacts/$ART_ID/zip"
rm -rf artifact && mkdir artifact
cd artifact && python -m zipfile -e ../dylibs.zip . && ls -la && cd ..

DYLIB="artifact/MeowRotate3D.dylib"
[ -f "$DYLIB" ] || DYLIB=$(find artifact -name "MeowRotate3D.dylib" | head -1)
[ -f "$DYLIB" ] || { echo "产物里没有 MeowRotate3D.dylib"; exit 1; }

echo "== [5/6] 注入 r19 IPA =="
IPA="/c/Users/XOS/Documents/AM_Tools/猫鹤AM-Meow-865_装这个_r19_0a5328d3_LCSign待签.ipa"
OUT="/c/Users/XOS/Documents/AM_Tools/猫鹤AM-Meow-865_r20_meow3d侦察版_LCSign待签.ipa"
rm -rf r20_work && mkdir r20_work
cd r20_work
python -m zipfile -e "$IPA" payload_extract
APPDIR=$(find payload_extract -name "AlightMotion.app" -type d | head -1)
cp "../$DYLIB" "$APPDIR/Frameworks/MeowRotate3D.dylib"
python ../inject_dylib.py "$APPDIR/AlightMotion" "@executable_path/Frameworks/MeowRotate3D.dylib"
# 重打包 (zip 内首层为 Payload/)
rm -f "$OUT"
python - "$OUT" << 'PYEOF'
import zipfile, os, sys
root = 'payload_extract'
out = sys.argv[1]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for dirpath, dirs, files in os.walk(root):
        for f in files:
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root).replace(os.sep, '/')
            z.write(full, rel)
print("repacked ->", out)
PYEOF
cd ..

echo "== [6/6] 完成 =="
echo "测试包: $OUT"
