#!/bin/zsh
# Inputscape 一键构建脚本
# - 显式检查构建退出码（防止 M6 式"管道掩盖编译失败"事故）
# - 使用 Apple Development 证书签名（签名身份稳定 → TCC 授权跨构建保留，
#   无需每次重新到系统设置授权；ad-hoc 签名 `-s -` 会重置授权）
set -e
ROOT="${0:A:h}"
IDENTITY="Apple Development: zfr45682@icloud.com (QV66DS6862)"
BUNDLE="$ROOT/build/Inputscape.app"

# 1) 构建（swift build 失败不立即中止，先取退出码再检查——set -e 下
#    "命令 + if [ $? ]" 的写法会在失败行直接中止且看不到日志）
DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release --disable-sandbox > /tmp/build-release.log 2>&1 || {
    echo "BUILD FAILED:"
    tail -30 /tmp/build-release.log
    exit 1
}
tail -2 /tmp/build-release.log

# 2) 停掉运行中的旧实例（无运行实例时 pgrep 返回 1，需容忍）
PIDS=$(pgrep -f "Inputscape.app/Contents/MacOS/Inputscape" || true)
if [ -n "$PIDS" ]; then
    kill -9 $PIDS
    sleep 1
fi

# 3) 安装 + 稳定身份签名
cp "$ROOT/.build/release/Inputscape" "$BUNDLE/Contents/MacOS/Inputscape"
codesign --force --sign "$IDENTITY" "$BUNDLE"
codesign --verify "$BUNDLE"

# 4) 启动
open "$BUNDLE"
echo "Inputscape built, signed (stable identity) and launched."
