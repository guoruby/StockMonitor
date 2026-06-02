#!/bin/bash

# 股票价格监控 - macOS 应用程序打包脚本

echo "========================================="
echo "开始打包股票价格监控应用程序"
echo "========================================="

# 检查 Python 版本
echo "检查 Python 环境..."
python3 --version

# 检查 py2app
if ! pip3 show py2app &> /dev/null; then
    echo ""
    echo "安装 py2app..."
    pip3 install py2app
else
    echo "py2app 已安装"
fi

# 清理之前的构建
echo ""
echo "清理之前的构建文件..."
rm -rf build dist

# 创建空的配置文件（如果不存在）
if [ ! -f monitor_config.json ]; then
    echo "创建默认配置文件..."
    cat > monitor_config.json << EOF
{
  "monitor_region": {
    "top": 0,
    "left": 0,
    "width": 200,
    "height": 40
  }
}
EOF
fi

# 构建应用程序
echo ""
echo "开始构建应用程序..."
python3 setup.py py2app

# 检查构建结果
if [ -d "dist/股票价格监控.app" ]; then
    echo ""
    echo "========================================="
    echo "打包成功！"
    echo "========================================="
    echo "应用程序位置: dist/股票价格监控.app"
    echo ""
    echo "使用说明："
    echo "1. 将应用程序拖拽到 Applications 文件夹"
    echo "2. 首次运行可能需要在系统设置中允许"
    echo "3. 右键点击应用程序 -> 打开"
    echo ""
    echo "注意："
    echo "- 应用程序需要屏幕录制权限（用于截图）"
    echo "- 首次运行会提示授予权限"
    echo "- 请在系统设置 -> 隐私与安全性 -> 屏幕录制中授权"
    echo "========================================="

    # 生成 DMG（可选）
    echo ""
    echo "创建 DMG 安装包..."
    if command -v hdiutil &> /dev/null; then
        hdiutil create -volname "股票价格监控" -srcfolder dist -ov -format UDZO "股票价格监控.dmg"
        echo "DMG 文件已创建: 股票价格监控.dmg"
    else
        echo "hdiutil 不可用，跳过 DMG 创建"
        echo "您可以手动压缩 .app 文件进行分发"
    fi
else
    echo ""
    echo "========================================="
    echo "打包失败，请检查错误信息"
    echo "========================================="
    exit 1
fi
