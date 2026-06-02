#!/bin/bash
# Alfred 启动脚本 - 设置完整环境变量

# 设置 PATH，确保能找到 tesseract
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

cd /Users/guoruby/code/monitorprice

# 检查是否已有监控程序在运行
if pgrep -f "stock_monitor_final.py" > /dev/null; then
    echo "监控程序已在运行"
    exit 0
fi

# 使用虚拟环境 Python 启动
/Users/guoruby/code/monitorprice/.venv/bin/python stock_monitor_final.py > /dev/null 2>&1 &

echo "股票监控已启动"
