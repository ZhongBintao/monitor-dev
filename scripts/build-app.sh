#!/bin/zsh
# Inputscape 构建脚本：从仓库从零组装 build/Inputscape.app（不依赖手工留存的 bundle）。
# - 显式检查构建退出码（防止"管道掩盖编译失败"）
# - 稳定签名身份 + 固定 bundle id → TCC 授权（辅助功能 / 输入监控）跨构建保留；
#   ad-hoc 签名 `-s -` 会重置授权
# 用法：scripts/build-app.sh [--no-open]
#   INPUTSCAPE_SIGN_ID 可覆盖签名身份
set -e
ROOT="${0:A:h:h}"
IDENTITY="${INPUTSCAPE_SIGN_ID:-Apple Development: zfr45682@icloud.com (QV66DS6862)}"
BUNDLE="$ROOT/build/Inputscape.app"
STAGING="$ROOT/build/.staging/Inputscape.app"
LOG="$ROOT/.build/build-app.log"
OPEN=1
[[ "$1" == "--no-open" ]] && OPEN=0

# 1) 构建
mkdir -p "$ROOT/.build"
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release --disable-sandbox \
    --package-path "$ROOT" > "$LOG" 2>&1 || {
    echo "BUILD FAILED (full log: $LOG):"
    tail -30 "$LOG"
    exit 1
}
tail -2 "$LOG"
BIN_DIR="$(DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release --disable-sandbox \
    --package-path "$ROOT" --show-bin-path)"

# 2) 在暂存目录组装 bundle：可执行文件 + Info.plist + SwiftPM 资源包
rm -rf "$ROOT/build/.staging"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/Inputscape" "$STAGING/Contents/MacOS/Inputscape"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
sed "s/__BUILD_NUMBER__/$BUILD_NUMBER/" "$ROOT/Packaging/Info.plist" > "$STAGING/Contents/Info.plist"
for res in "$BIN_DIR"/*.bundle(N); do
    cp -R "$res" "$STAGING/Contents/Resources/"
done

# 3) 签名并校验
codesign --force --sign "$IDENTITY" "$STAGING"
codesign --verify "$STAGING"

# 4) 优雅退出运行中的实例（触发 applicationWillTerminate 落盘），超时再强杀
if pgrep -f "Inputscape.app/Contents/MacOS/Inputscape" > /dev/null; then
    osascript -e 'tell application id "com.bintao.Inputscape" to quit' > /dev/null 2>&1 || true
    for _ in {1..10}; do
        pgrep -f "Inputscape.app/Contents/MacOS/Inputscape" > /dev/null || break
        sleep 0.5
    done
    PIDS=$(pgrep -f "Inputscape.app/Contents/MacOS/Inputscape" || true)
    [ -n "$PIDS" ] && kill -9 $PIDS && sleep 1
fi

# 5) 替换正式 bundle
rm -rf "$BUNDLE"
mv "$STAGING" "$BUNDLE"
rm -rf "$ROOT/build/.staging"
echo "Built and signed $BUNDLE (build $BUILD_NUMBER)."

[[ $OPEN == 1 ]] && open "$BUNDLE" && echo "Launched."
exit 0
