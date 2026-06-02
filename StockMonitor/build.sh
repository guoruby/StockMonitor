#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="股票价格监控"
APP_BUNDLE="dist/${APP_NAME}.app"
EXECUTABLE="StockMonitor"
SIGNING_IDENTITY="StockMonitor Signing"
BUNDLE_ID="com.stockmonitor.app"

echo "========================================="
echo "原生 Mac App 打包"
echo "========================================="

echo "编译 Release..."
swift build -c release 2>&1 | tail -5

echo "创建 App Bundle..."
rm -rf dist
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${EXECUTABLE}" "${APP_BUNDLE}/Contents/MacOS/"
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>StockMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.stockmonitor.app</string>
    <key>CFBundleName</key>
    <string>股票价格监控</string>
    <key>CFBundleDisplayName</key>
    <string>股票价格监控</string>
    <key>CFBundleVersion</key>
    <string>2.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>2.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>需要截取屏幕区域来识别同花顺中的股票名称和价格</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>需要屏幕录制权限以识别股票价格</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "设置权限..."
chmod +x "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE}"

echo "代码签名..."
if security find-identity -v -p codesigning | grep -q "${SIGNING_IDENTITY}"; then
    codesign --sign "${SIGNING_IDENTITY}" --force --identifier "${BUNDLE_ID}" "${APP_BUNDLE}" 2>&1
    echo "✅ 已用 ${SIGNING_IDENTITY} 签名（屏幕录制权限不会因重新编译而重置）"
else
    codesign --sign - --force --identifier "${BUNDLE_ID}" "${APP_BUNDLE}" 2>&1
    echo "⚠️  使用 ad-hoc 签名（每次编译可能需要重新授权屏幕录制）"
    echo "   建议创建代码签名证书以避免重复授权："
    echo "   钥匙串访问 → 证书助理 → 创建证书 → 代码签名"
fi

echo "清除隔离属性..."
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

echo ""
echo "========================================="
echo "✅ 打包完成!"
echo "========================================="
du -sh "${APP_BUNDLE}"
echo ""
echo "App: ${APP_BUNDLE}"
echo ""
echo "运行: open \"${APP_BUNDLE}\""
