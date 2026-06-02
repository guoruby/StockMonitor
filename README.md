# StockMonitor

macOS 原生股票价格监控工具，通过 OCR 识别同花顺中的股票名称和价格，实时显示偏离度和振幅。

## 功能

- **OCR 识别**：基于 Vision.framework 自动识别屏幕区域的股票名称和价格
- **实时行情**：通过腾讯 API 获取涨跌幅、振幅等数据
- **VWAP 分析**：基于分时数据的成交量加权均价分析
- **浮动窗口**：轻量悬浮窗，始终置顶显示核心数据
- **全局快捷键**：Carbon API 实现，随时启停监控

## 构建

```bash
cd StockMonitor
./build.sh
```

构建产物在 `StockMonitor/dist/股票价格监控.app`。

## 运行

```bash
open "StockMonitor/dist/股票价格监控.app"
```

## 权限

首次运行需要授予：

1. **屏幕录制权限** — 用于 OCR 识别屏幕内容
2. **辅助功能权限** — 用于全局快捷键

在 `系统设置 → 隐私与安全性` 中开启。

## 代码签名

建议创建自签名证书避免每次编译后重新授权：

1. 打开 `钥匙串访问 → 证书助理 → 创建证书`
2. 名称填 `StockMonitor Signing`，类型选 `代码签名`
3. 之后 `build.sh` 会自动使用该证书签名

## 系统要求

- macOS 13.0+
- Xcode Command Line Tools

## License

MIT
