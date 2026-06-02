#!/bin/bash

# Alfred workflow 脚本 - 启动股票监控
cd /Users/guoruby/code/monitorprice

# 检查是否已有监控程序在运行
if pgrep -f "stock_monitor_final.py" > /dev/null; then
    echo "监控程序已在运行"
else
    # 后台启动
    nohup python3 stock_monitor_final.py > /dev/null 2>&1 &
    echo "股票监控已启动"
fi
