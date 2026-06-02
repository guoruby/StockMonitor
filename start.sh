#!/bin/bash
# 启动股票价格监控程序

# 切换到脚本所在目录
#cd "/bin"

echo "启动股票价格监控程序..."

# 检查虚拟环境
if [ -d ".venv" ]; then
    echo "使用虚拟环境运行..."
    # 激活虚拟环境并运行程序
    source .venv/bin/activate && python stock_monitor_final.py &
else
    echo "未找到虚拟环境，使用系统Python运行..."
    python3 stock_monitor_final.py &
fi
