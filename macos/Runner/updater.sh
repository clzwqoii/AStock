#!/bin/bash
# macOS 自更新执行器：解压 zip → 备份旧版 → 替换 → 校验 → 重启 → 清理。
#
# 由 App 通过 Swift 端 MethodChannel 唤起后**立即退出自身**，脚本在 App 退出后
# 才真正动手。必须如此：运行中的进程无法可靠替换自己（正在执行的 Mach-O 被内核锁定），
# 这也是 Sparkle 等成熟方案的做法。
#
# 用法: updater.sh --zip <安装包.zip> --target /Applications/ASTock.app [--dry-run] [--no-relaunch]
#
# 关键约束（每条都有 test/updater_script_test.dart 锁住）：
# - 必须用 `ditto` 而非 `cp -R` 复制 app：实测 cp -R 会破坏 adhoc 签名，
#   替换后 app 变成 "code object is not signed at all" 直接打不开。
# - 先在临时目录解压并校验，再替换；任何环节失败都必须让旧版原封不动。
# - 成功后清理 zip、备份与工作目录，不留残渣。
set -uo pipefail

# bash 在 C locale 下按字节解析变量名，变量紧贴中文字符会被并进变量名
# （如 "$NEW_VER（" 会变成变量 NEW_VER…，报 unbound variable）。
# 固定 UTF-8 locale 从根上避免；即便如此，正文里变量仍一律写成 ${VAR}。
export LC_ALL=en_US.UTF-8

ZIP=""
TARGET=""
DRY_RUN=0
RELAUNCH=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip) ZIP="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-relaunch) RELAUNCH=0; shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ZIP" || -z "$TARGET" ]]; then
  echo "用法: updater.sh --zip <安装包.zip> --target <已安装.app 路径> [--dry-run] [--no-relaunch]" >&2
  exit 2
fi

fail() { echo "更新失败：$*" >&2; exit 1; }

[[ -f "$ZIP" ]] || fail "安装包不存在: $ZIP"
[[ -d "$TARGET" ]] || fail "目标 app 不存在: $TARGET"

# ditto / codesign 都要求真实路径：macOS 临时目录是 /var → /private/var 符号链接，
# 直接用会在解压时报 "Cannot get the real path for source"。
resolve() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1"
  else
    printf '%s' "$1"
  fi
}
ZIP="$(resolve "$ZIP")"
TARGET="$(resolve "$TARGET")"

TARGET_DIR="$(cd "$(dirname "$TARGET")" && pwd)"
TARGET_BASE="$(basename "$TARGET")"          # ASTock.app
APP_NAME="${TARGET_BASE%.app}"               # ASTock

WORK="$(mktemp -d "${TMPDIR:-/tmp}/astock_update.XXXXXX")" || fail "无法创建工作目录"
WORK="$(resolve "$WORK")"
STAGE="$WORK/staged"
BACKUP="$WORK/backup"
LOG_PREFIX="[astock-updater]"

log() { echo "$LOG_PREFIX $*"; }

# 无论成功失败都清工作目录；ZIP 只在成功后删（失败时留着给用户重试/排查）。
cleanup_work() { rm -rf "$WORK"; }
trap cleanup_work EXIT

# ── 1. 解压 ──────────────────────────────────────────────────────
log "解压 $ZIP"
mkdir -p "$STAGE"
# ditto 自带 zip 支持，无需外部 unzip，且保留权限与扩展属性（签名相关）。
if ! ditto -x -k "$ZIP" "$STAGE" 2>/dev/null; then
  fail "解压失败（文件可能损坏或不完整）"
fi

NEW_APP="$STAGE/$TARGET_BASE"
[[ -d "$NEW_APP" ]] || fail "安装包里没有 $TARGET_BASE"

# ── 2. 替换前校验：二进制在、Info.plist 在、签名有效 ──────────────
EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
  "$NEW_APP/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$EXE_NAME" && -f "$NEW_APP/Contents/MacOS/$EXE_NAME" ]] \
  || fail "新版本缺少可执行文件"

if ! codesign -v "$NEW_APP" 2>/dev/null; then
  fail "新版本签名校验未通过（包可能损坏）"
fi

if [[ $DRY_RUN == 1 ]]; then
  NEW_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$NEW_APP/Contents/Info.plist" 2>/dev/null || echo '未知')"
  log "演练通过：将把 ${APP_NAME} 升级到 ${NEW_VER}（dry-run，未做任何改动）"
  exit 0
fi

# ── 3. 备份旧版（失败时用它回滚）────────────────────────────────
OLD_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$TARGET/Contents/Info.plist" 2>/dev/null || echo '未知')"
log "当前版本 $OLD_VER → 准备替换"

cp -R "$TARGET" "$BACKUP" 2>/dev/null || true  # 备份只是保险，失败不阻断

# ── 4. 替换：先移到一边，再 ditto 就位 ───────────────────────────
# 不用「直接覆盖」：中途失败会留下半个 app。移走旧版后，若新版本有问题
# 还能把 backup 移回来；替换是同分区 rename，接近原子。
STALE="$WORK/stale.app"
if ! mv "$TARGET" "$STALE" 2>/dev/null; then
  fail "无法移走旧版本（$TARGET_DIR 是否可写？）"
fi

if ! ditto "$NEW_APP" "$TARGET" 2>/dev/null; then
  # 回滚：把旧版放回原位
  ditto "$STALE" "$TARGET" 2>/dev/null || cp -R "$STALE" "$TARGET" 2>/dev/null
  fail "替换失败，已回滚到 $OLD_VER"
fi

# ── 5. 替换后校验：签名与可执行性都要过 ─────────────────────────
if ! codesign -v "$TARGET" 2>/dev/null; then
  # 新版本装上去却坏了 —— 立刻回滚，绝不把用户留在打不开的状态
  rm -rf "$TARGET"
  ditto "$STALE" "$TARGET" 2>/dev/null || cp -R "$STALE" "$TARGET" 2>/dev/null
  fail "新版本安装后校验失败，已回滚到 $OLD_VER"
fi

NEW_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$TARGET/Contents/Info.plist" 2>/dev/null || echo '未知')"
log "已替换为 $NEW_VER"

# ── 6. 清理：删旧版、删安装包（本条是你要求的行为）───────────────
rm -rf "$STALE"
if rm -f "$ZIP" 2>/dev/null; then
  log "已删除安装包 $(basename "$ZIP")"
else
  log "警告：安装包删除失败，请手动清理 $ZIP"
fi

# ── 7. 重启新版本 ────────────────────────────────────────────────
if [[ $RELAUNCH == 1 ]]; then
  log "启动新版本"
  # 等旧进程真正退出再启动，否则 LaunchServices 会激活旧实例。
  sleep 1
  open -a "$TARGET"
fi

log "完成"
exit 0
