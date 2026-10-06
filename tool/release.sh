#!/bin/bash
# 一键发版：更新版本号 → 构建双端安装包 → 推送双平台 → GitHub + Gitee 双发行版
# 用法：tool/release.sh 1.1.0 [--dry-run]   （--dry-run 只做版本号检查与本地构建，不推送/不发行）
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1
if [[ -z "$VERSION" ]]; then
  echo "用法: tool/release.sh <版本号 如 1.1.0> [--dry-run]" >&2
  exit 1
fi

GITEE_REPO="clzwqoii/astock"
GH_REPO="clzwqoii/AStock"
TAG="v$VERSION"

# 国内网络：flutter/pub 走镜像
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# 勿在字符串里让变量紧贴中文字符（如 "$VERSION（"）：bash 在 C locale 下按字节解析，
# 会把中文并进变量名报 unbound variable。export LANG 对已运行的 bash 无效，用 printf 才是正解。

step() { echo; echo "=== $* ==="; }

step "1/7 校验版本号"
grep -q "^version: $VERSION+" pubspec.yaml || { echo "pubspec.yaml 版本号需为 $VERSION"; exit 1; }
grep -q "kAppVersion = '$VERSION'" lib/app_logic.dart || { echo "lib/app_logic.dart 的 kAppVersion 需为 '$VERSION'"; exit 1; }
grep -q "\"version\": \"$VERSION\"" update.json || { echo "update.json 版本号需为 $VERSION"; exit 1; }
# 应用内下载需要安装包直链；Windows 包产出后同样补 windows 字段。
# macOS 主直链是 **zip**（assets.macos）——应用内自替换走 updater.sh 解压替换，
# dmg 仍要产出（给手动分发与首装），但只在 assets.macos_dmg 里留一条兜底。
grep -q "download/v$VERSION/AStock-$VERSION-Android.apk" update.json || { echo "update.json 缺少 v$VERSION 的安卓包直链（assets 字段）"; exit 1; }
grep -q "download/v$VERSION/AStock-$VERSION-macOS.zip" update.json || { echo "update.json 缺少 v$VERSION 的 macOS zip 直链（assets.macos，自替换用）"; exit 1; }
grep -q "download/v$VERSION/AStock-$VERSION-macOS.dmg" update.json || { echo "update.json 缺少 v$VERSION 的 macOS dmg 直链（assets.macos_dmg，手动分发用）"; exit 1; }
echo "版本号一致: $VERSION"

step "2/7 清理临时副本并构建 Android"
rm -rf build/dmg
flutter build apk --release --build-name="$VERSION"
cp build/app/outputs/flutter-apk/app-release.apk "/tmp/AStock-$VERSION-Android.apk"

step "3/7 构建 macOS，打 zip（应用内自替换）与 dmg（手动分发）"
flutter build macos --release

# zip 供应用内自替换：updater.sh 用 `ditto -x -k` 解压，再用 `ditto` 就位。
# 必须用 zip -y（保留符号链接）而非 ditto -c -k：后者在 macOS 临时目录下会报
# "Cannot get the real path for source"。解压侧仍用 ditto——签名保真靠它。
rm -f "/tmp/AStock-$VERSION-macOS.zip"
(cd build/macos/Build/Products/Release && zip -qry -y "/tmp/AStock-$VERSION-macOS.zip" ASTock.app)

mkdir -p build/dmg
cp -R build/macos/Build/Products/Release/ASTock.app build/dmg/
ln -sf /Applications build/dmg/Applications
rm -f "build/A股选股台.dmg"
hdiutil create -volname 'A股选股台' -srcfolder build/dmg -ov -format UDZO "build/A股选股台.dmg"
cp "build/A股选股台.dmg" "/tmp/AStock-$VERSION-macOS.dmg"

if [[ $DRY_RUN == 1 ]]; then
  step "dry-run 结束：未推送、未创建发行版"
  echo "产物: build/app/outputs/flutter-apk/app-release.apk, /tmp/AStock-$VERSION-macOS.zip, build/A股选股台.dmg"
  exit 0
fi

step "4/7 提交并推送双平台"
git add -A
git commit -m "release: v$VERSION" || echo "无内容变更，跳过提交"
git push gitee main
git push github main
git tag -f "$TAG" main
git push gitee "$TAG" -f || true
git push github "$TAG" -f || true

step "5/7 GitHub 发行版"
NOTES=$(mktemp)
sed -n "/^## $VERSION/,/^## /p" RELEASE_NOTES.md | sed '$d' > "$NOTES"
[[ -s "$NOTES" ]] || printf 'A股规则选股 %s（四端通用）。详见仓库 README。\n' "$VERSION" > "$NOTES"
gh release delete "$TAG" --repo "$GH_REPO" -y 2>/dev/null || true
gh release create "$TAG" --repo "$GH_REPO" --title "$TAG · A股规则选股工具（四端）" \
  --notes-file "$NOTES" "/tmp/AStock-$VERSION-macOS.zip" "/tmp/AStock-$VERSION-macOS.dmg" "/tmp/AStock-$VERSION-Android.apk"
rm -f "$NOTES"

step "6/7 Gitee 发行版"
GITEE_TOKEN="${GITEE_TOKEN:-$(security find-generic-password -s gitee-release -a clzwqoii -w 2>/dev/null || true)}"
if [[ -z "$GITEE_TOKEN" ]]; then
  echo "跳过 Gitee 发行版：未找到令牌。"
  echo "设置方式（二选一）："
  echo "  1) security add-generic-password -s gitee-release -a clzwqoii -w <你的Gitee私人令牌>"
  echo "  2) GITEE_TOKEN=<令牌> tool/release.sh $VERSION"
  exit 0
fi
python3 - "$VERSION" "$TAG" "$GITEE_TOKEN" <<'PY'
import json, sys, urllib.request, uuid, mimetypes, pathlib

version, tag, token = sys.argv[1], sys.argv[2], sys.argv[3]
owner_repo = "clzwqoii/astock"
notes_file = pathlib.Path("RELEASE_NOTES.md").read_text(encoding="utf-8")
head = f"## v{version}"
if head not in notes_file:
    head = f"## {version}"
body = notes_file.split(head, 1)[1].split("\n## ", 1)[0].strip() if head in notes_file else f"v{version}"

def post_json(url, data):
    req = urllib.request.Request(url, data=json.dumps(data).encode(), headers={"Content-Type": "application/json"})
    req.add_header("Authorization", f"token {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())

def post_file(url, path, fields):
    boundary = uuid.uuid4().hex
    parts = []
    for k, v in fields.items():
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode())
    p = pathlib.Path(path)
    ctype = mimetypes.guess_type(p.name)[0] or "application/octet-stream"
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{p.name}\"\r\nContent-Type: {ctype}\r\n\r\n".encode())
    parts.append(p.read_bytes())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    req = urllib.request.Request(url, data=b"".join(parts), headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    req.add_header("Authorization", f"token {token}")
    with urllib.request.urlopen(req, timeout=600) as r:
        return r.read().decode()[:200]

base = f"https://gitee.com/api/v5/repos/{owner_repo}"
rel = post_json(f"{base}/releases?access_token={token}", {
    "tag_name": tag, "name": tag, "body": body, "target_commitish": "main", "prerelease": False,
})
rid = rel["id"]
print(f"Gitee 发行版已创建 id={rid}: https://gitee.com/{owner_repo}/releases")
for f in [f"/tmp/AStock-{version}-macOS.zip", f"/tmp/AStock-{version}-macOS.dmg", f"/tmp/AStock-{version}-Android.apk"]:
    post_file(f"{base}/releases/{rid}/attach_files", f, {"access_token": token, "name": pathlib.Path(f).name})
    print(f"已上传 {pathlib.Path(f).name}")
PY

step "7/7 完成"
echo "GitHub: https://github.com/$GH_REPO/releases/tag/$TAG"
echo "Gitee:  https://gitee.com/$GITEE_REPO/releases"
echo "update.json 下载链接指向 releases/list 页面，App 检查更新会自动带上新版本。"