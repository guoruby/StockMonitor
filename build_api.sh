#!/bin/bash
set -e

echo "========================================="
echo "股票价格监控 - API 模式打包"
echo "========================================="

if [ ! -d ".venv" ]; then
    echo "创建虚拟环境..."
    python3 -m venv .venv
fi

echo "激活虚拟环境..."
source .venv/bin/activate

echo "安装依赖..."
pip install -q --upgrade pip
pip install -q -r requirements_api.txt
pip install -q pyinstaller

echo "清理旧构建..."
rm -rf build dist

echo "开始打包..."
pyinstaller --clean stock_monitor.spec

if [ -d "dist/股票价格监控.app" ]; then
    echo ""
    echo "========================================="
    echo "✅ 打包成功！"
    echo "========================================="
    echo "应用程序: dist/股票价格监控.app"
    ls -lh dist/
    echo ""
    
    if command -v hdiutil &> /dev/null; then
        echo "创建 DMG..."
        hdiutil create -volname "股票价格监控 v2.0" -srcfolder dist -ov -format UDZO "股票价格监控 v2.0.dmg"
        echo "DMG: 股票价格监控 v2.0.dmg"
    fi
else
    echo "❌ 打包失败"
    exit 1
fi
