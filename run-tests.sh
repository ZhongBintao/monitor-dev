#!/bin/zsh
# Inputscape 测试运行脚本：
# 本机 Xcode 许可未接受（xcodebuild / swift test 不可用），CommandLineTools 又不带 XCTest。
# 因此用 CLT 的 swiftc 编译 Kit（-enable-testing），用 Xcode 的 XCTest.framework
# 链接出 .xctest bundle，再用 Xcode 的 xctest 运行器执行。不需要接受 Xcode 许可。
set -e
ROOT="${0:A:h}"
XCFW=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
XL=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
SWIFT="DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc"
BUNDLE="$ROOT/.build/xctest/InputscapeKitTests.xctest"

rm -rf "$ROOT/.build/xctest"
mkdir -p "$BUNDLE/Contents/MacOS"

# 1) Kit 动态库（可测试模块）
env DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc \
  -parse-as-library -module-name InputscapeKit -enable-testing \
  -emit-module -emit-module-path "$ROOT/.build/xctest/InputscapeKit.swiftmodule" \
  -emit-library -o "$ROOT/.build/xctest/libInputscapeKit.dylib" \
  -F /System/Library/PrivateFrameworks -framework MultitouchSupport \
  "$ROOT"/Sources/InputscapeKit/*.swift

# 2) 测试 bundle
# InputscapeKit 依赖 MultitouchSupport（私有框架，TouchpointMonitor），
# 链接时需显式指向 SDK 的 PrivateFrameworks（与 Package.swift 的 linkerSettings 对应）。
env DEVELOPER_DIR=/Library/Developer/CommandLineTools swiftc \
  -parse-as-library -I "$XL" -I "$ROOT/.build/xctest" -F "$XCFW" \
  "$ROOT"/Tests/InputscapeKitTests/*.swift \
  -L "$ROOT/.build/xctest" -L "$XL" -lInputscapeKit -lXCTestSwiftSupport -framework XCTest \
  -F /System/Library/PrivateFrameworks -framework MultitouchSupport \
  -Xlinker -bundle \
  -Xlinker -rpath -Xlinker "$XCFW" \
  -Xlinker -rpath -Xlinker "$XL" \
  -Xlinker -rpath -Xlinker "$ROOT/.build/xctest" \
  -o "$BUNDLE/Contents/MacOS/InputscapeKitTests"

# 3) Info.plist
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>InputscapeKitTests</string>
<key>CFBundleIdentifier</key><string>com.bintao.InputscapeKitTests</string>
<key>CFBundlePackageType</key><string>BNDL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST

# 4) 运行
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest "$BUNDLE"
