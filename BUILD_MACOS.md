# macOS 应用程序打包说明

## 快速打包

### 方法一：使用自动化脚本（推荐）

```bash
cd /Users/guoruby/code/monitorprice
./build_app.sh
```

### 方法二：手动打包

```bash
# 1. 安装依赖
pip3 install -r requirements_ocr.txt
pip3 install py2app

# 2. 清理之前的构建
rm -rf build dist

# 3. 创建配置文件（如果不存在）
if [ ! -f monitor_config.json ]; then
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

# 4. 构建应用程序
python3 setup.py py2app

# 5. 查看结果
ls -lh dist/
```

## 使用说明

### 安装

1. 打开 `dist` 文件夹
2. 将 `股票价格监控.app` 拖拽到 `Applications` 文件夹

### 首次运行

1. 在 Launchpad 或 Applications 中找到 `股票价格监控`
2. **右键点击** -> 选择"打开"（首次必须这样打开）
3. 系统会弹出安全提示，点击"打开"

### 授予权限

应用程序需要以下权限：

1. **屏幕录制权限**（用于截图）
   - 打开 `系统设置` -> `隐私与安全性` -> `屏幕录制`
   - 找到 `股票价格监控`，打开开关

2. **辅助功能权限**（用于窗口控制，可选）
   - 打开 `系统设置` -> `隐私与安全性` -> `辅助功能`
   - 找到 `股票价格监控`，打开开关

### 卸载

1. 停止应用程序
2. 将 `股票价格监控.app` 移到废纸篓

## 注意事项

1. **首次运行必须右键打开**，直接双击会提示"无法打开"
2. 需要 Tesseract OCR 才能识别真实价格
   ```bash
   # 安装 Tesseract
   brew install tesseract
   brew install tesseract-lang
   ```
3. 如果遇到权限问题，在系统设置中手动授予权限
4. 应用程序会自动创建配置文件在用户目录

## 故障排除

### 打包失败

```bash
# 清理并重试
rm -rf build dist
pip3 install --upgrade py2app
python3 setup.py py2app
```

### 无法打开应用程序

```bash
# 移除隔离属性
xattr -cr "dist/股票价格监控.app"
```

### 应用程序闪退

查看系统日志：
```bash
log show --predicate 'process == "股票价格监控"' --last 5m
```

## 分发

将 `dist/股票价格监控.app` 打包：

```bash
# 创建 DMG 安装包（需要 hdiutil）
hdiutil create -volname "股票价格监控" -srcfolder dist -ov -format UDZO 股票价格监控.dmg
```

## 构建产物

```
dist/
└── 股票价格监控.app/
    └── Contents/
        ├── MacOS/
        │   └── stock_monitor_final  # 可执行文件
        ├── Resources/
        │   └── monitor_config.json  # 配置文件
        └── Info.plist
```
