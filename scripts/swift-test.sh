#!/bin/zsh
# 用 CommandLineTools 运行 Swift Testing（`import Testing`）测试。
# CLT 自带 Testing.framework，但不在默认搜索路径上，需显式传 -F 与 rpath（Phase 0 · P0 实测）。
# CLT 不带 XCTest：旧的 XCTest 测试仍走 run-tests.sh，迁移完成前本脚本只适用于 Swift Testing 目标。
# 用法：scripts/swift-test.sh [swift test 的其他参数，如 --filter RhythmTests]
set -e
ROOT="${0:A:h:h}"
CLT=/Library/Developer/CommandLineTools
FW="$CLT/Library/Developer/Frameworks"
LIB="$CLT/Library/Developer/usr/lib"
DEVELOPER_DIR="$CLT" swift test --disable-sandbox --package-path "$ROOT" \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" \
    "$@"
