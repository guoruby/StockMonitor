#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
股票价格监控 v2.0
Vision OCR 识别股票名+价格 + 腾讯 API 补充量价分析
"""
import sys
import os
import json
import re
from datetime import datetime
from PyQt5.QtWidgets import (
    QApplication, QWidget, QLabel, QVBoxLayout, QHBoxLayout,
    QPushButton, QDialog, QLineEdit, QMessageBox, QCheckBox,
    QShortcut, QGroupBox
)
from PyQt5.QtCore import Qt, QTimer, QPoint
from PyQt5.QtGui import QFont, QColor, QPalette, QKeySequence

import Quartz
import Vision
import objc
import requests

CONFIG_DIR = os.path.expanduser("~/Library/Application Support/StockMonitor")
os.makedirs(CONFIG_DIR, exist_ok=True)
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
LOG_FILE = os.path.join(CONFIG_DIR, "ocr.log")

DEFAULT_CONFIG = {
    "monitor_region": {"top": 587, "left": 342, "width": 208, "height": 15},
    "ocr_region": {"top": 95, "left": 275, "width": 180, "height": 55},
    "window_pos": {"x": 574, "y": 401},
    "mode": "ocr",
    "stock_code": "603687",
    "update_interval": 700
}

def log(message):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(LOG_FILE, "a", encoding="utf-8") as f:
        f.write(f"[{timestamp}] {message}\n")

def load_config():
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                cfg = json.load(f)
                for k, v in DEFAULT_CONFIG.items():
                    if k not in cfg:
                        cfg[k] = v
                return cfg
        except Exception:
            pass
    return DEFAULT_CONFIG.copy()

def save_config(cfg):
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

def get_realtime_data(stock_code):
    try:
        if stock_code.startswith("6"):
            code = f"sh{stock_code}"
        elif stock_code.startswith(("0", "3")):
            code = f"sz{stock_code}"
        else:
            code = stock_code
        
        url = f"https://qt.gtimg.cn/q={code}"
        r = requests.get(url, timeout=5)
        r.encoding = "gbk"
        text = r.text.strip()
        if "~" not in text:
            return None
        
        parts = text.split("~")
        if len(parts) < 50 or not parts[3]:
            return None
        
        price = float(parts[3])
        name = parts[1]
        change_pct = float(parts[32]) if parts[32] else 0
        volume = int(parts[6]) * 100 if parts[6] else 0
        amount = float(parts[37]) * 10000 if parts[37] else 0
        vwap = amount / volume if volume > 0 else price
        vol_ratio = float(parts[46]) if len(parts) > 46 and parts[46] else 1.0
        
        buy_volume = int(parts[7]) * 100 if parts[7] else 0
        sell_volume = int(parts[8]) * 100 if parts[8] else 0
        net_flow = buy_volume - sell_volume
        flow_strength = (net_flow / volume * 100) if volume > 0 else 0
        
        return {
            "name": name,
            "code": stock_code,
            "price": price,
            "vwap": vwap,
            "change_pct": change_pct,
            "volume": volume,
            "amount": amount,
            "vol_ratio": vol_ratio,
            "deviation": (price - vwap) / vwap * 100 if vwap > 0 else 0,
            "flow_strength": flow_strength
        }
    except Exception as e:
        log(f"API 错误: {e}")
        return None

def vision_ocr(region):
    try:
        with objc.autorelease_pool():
            display = Quartz.CGMainDisplayID()
            rect = Quartz.CGRectMake(
                region["left"], region["top"],
                region["width"], region["height"]
            )
            cg_image = Quartz.CGDisplayCreateImageForRect(display, rect)
            if not cg_image:
                return []
            
            request = Vision.VNRecognizeTextRequest.alloc().init()
            request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
            request.setRecognitionLanguages_(["zh-Hans", "en"])
            request.setUsesLanguageCorrection_(True)
            
            handler = Vision.VNImageRequestHandler.alloc().initWithCGImage_options_(cg_image, None)
            success, error = handler.performRequests_error_([request], None)
            if not success:
                log(f"Vision 失败: {error}")
                return []
            
            results = []
            for res in request.results():
                text = res.topCandidates_(1)[0].string()
                conf = res.topCandidates_(1)[0].confidence()
                box = res.boundingBox()
                results.append({
                    "text": text,
                    "confidence": conf,
                    "box": {"x": box.origin.x, "y": box.origin.y, "w": box.size.width, "h": box.size.height}
                })
            return results
    except Exception as e:
        log(f"OCR 异常: {e}")
        return []

def parse_ocr_results(ocr_results):
    full_text = " ".join([r["text"] for r in ocr_results])
    
    result = {
        "code": None,
        "name": "",
        "avg_price": None,
        "current_price": None,
        "raw_text": full_text
    }
    
    code_match = re.search(r"\b(60[0-5]\d{3}|60[89]\d{3}|300\d{3}|00[0-3]\d{3}|000\d{3})\b", full_text)
    if code_match:
        result["code"] = code_match.group(1)
    
    avg_match = re.search(r"均价[:：\s]*([\d.]+)", full_text)
    if avg_match:
        result["avg_price"] = float(avg_match.group(1))
    
    current_match = re.search(r"(?:最新|现价|当前)[:：\s]*([\d.]+)", full_text)
    if current_match:
        result["current_price"] = float(current_match.group(1))
    
    name_match = re.match(r"^([\u4e00-\u9fa5]{2,4})", full_text)
    if name_match:
        result["name"] = name_match.group(1)
    
    return result

class StockMonitor(QWidget):
    def __init__(self):
        super().__init__()
        self.config = load_config()
        self.is_monitoring = False
        self.ocr_fail_count = 0
        self.last_ocr_result = {}
        
        self.setWindowFlags(Qt.Window)
        self.setAttribute(Qt.WA_MacAlwaysShowToolWindow, True)
        
        self.setup_ui()
        self.apply_config()
        
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_data)
        
        self.setup_shortcuts()
        self.set_theme()
        self.show()
        self.raise_()
        self.activateWindow()
    
    def setup_ui(self):
        self.setFixedSize(220, 150)
        
        self.name_label = QLabel("--")
        self.name_label.setAlignment(Qt.AlignCenter)
        self.name_label.setFont(QFont("Arial", 11, QFont.Bold))
        
        self.deviation_label = QLabel("--%")
        self.deviation_label.setAlignment(Qt.AlignCenter)
        self.deviation_label.setFont(QFont("Arial", 22, QFont.Bold))
        
        self.price_detail = QLabel("OCR: -- | API: --")
        self.price_detail.setAlignment(Qt.AlignCenter)
        self.price_detail.setFont(QFont("Arial", 9))
        self.price_detail.setStyleSheet("color: #666;")
        
        self.vwap_label = QLabel("VWAP: -- | 偏离: --%")
        self.vwap_label.setAlignment(Qt.AlignCenter)
        self.vwap_label.setFont(QFont("Arial", 9))
        self.vwap_label.setStyleSheet("color: #888;")
        
        self.signal_label = QLabel("")
        self.signal_label.setAlignment(Qt.AlignCenter)
        self.signal_label.setFont(QFont("Arial", 10))
        
        self.status_label = QLabel("就绪")
        self.status_label.setAlignment(Qt.AlignCenter)
        self.status_label.setFont(QFont("Arial", 8))
        self.status_label.setStyleSheet("color: #999;")
        
        self.toggle_btn = QPushButton("▶ 开始监控")
        self.toggle_btn.setFixedHeight(26)
        self.toggle_btn.clicked.connect(self.toggle_monitoring)
        
        self.settings_btn = QPushButton("⚙ 设置")
        self.settings_btn.setFixedHeight(26)
        self.settings_btn.clicked.connect(self.open_settings)
        
        btn_layout = QHBoxLayout()
        btn_layout.addWidget(self.toggle_btn)
        btn_layout.addWidget(self.settings_btn)
        
        layout = QVBoxLayout()
        layout.setSpacing(2)
        layout.setContentsMargins(8, 6, 8, 6)
        layout.addWidget(self.name_label)
        layout.addWidget(self.deviation_label)
        layout.addWidget(self.price_detail)
        layout.addWidget(self.vwap_label)
        layout.addWidget(self.signal_label)
        layout.addWidget(self.status_label)
        layout.addLayout(btn_layout)
        
        self.setLayout(layout)
    
    def set_theme(self):
        palette = QPalette()
        palette.setColor(QPalette.Window, QColor(255, 255, 255))
        palette.setColor(QPalette.WindowText, QColor(32, 32, 32))
        self.setPalette(palette)
    
    def apply_config(self):
        pos = self.config.get("window_pos", {"x": 574, "y": 401})
        self.move(pos["x"], pos["y"])
    
    def setup_shortcuts(self):
        shortcut = QShortcut(QKeySequence("Cmd+L"), self)
        shortcut.activated.connect(self.toggle_monitoring)
    
    def toggle_monitoring(self):
        self.is_monitoring = not self.is_monitoring
        
        if self.is_monitoring:
            self.timer.start(self.config.get("update_interval", 700))
            self.toggle_btn.setText("⏹ 停止")
            self.status_label.setText("监控中...")
            self.update_data()
        else:
            self.timer.stop()
            self.toggle_btn.setText("▶ 监控")
            self.status_label.setText("已停止")
    
    def update_data(self):
        try:
            stock_code = self.config.get("stock_code", "603687")
            ocr_current_price = None
            ocr_avg_price = None
            
            if self.config.get("mode", "ocr") == "ocr":
                ocr_region = self.config.get("ocr_region", DEFAULT_CONFIG["ocr_region"])
                ocr_results = vision_ocr(ocr_region)
                
                if ocr_results:
                    parsed = parse_ocr_results(ocr_results)
                    self.last_ocr_result = parsed
                    
                    if parsed["code"]:
                        old_code = self.config.get("stock_code")
                        if parsed["code"] != old_code:
                            stock_code = parsed["code"]
                            self.config["stock_code"] = stock_code
                            self.status_label.setText(f"切换: {parsed['name']} ({stock_code})")
                            log(f"OCR 切换股票: {parsed['name']} {stock_code}")
                    
                    ocr_current_price = parsed["current_price"]
                    ocr_avg_price = parsed["avg_price"]
                    
                    if parsed["name"]:
                        self.name_label.setText(parsed["name"])
                else:
                    self.ocr_fail_count += 1
                    if self.ocr_fail_count >= 5:
                        self.status_label.setText("OCR 连续失败，检查区域设置")
                    return
                
                self.ocr_fail_count = 0
            
            api_data = get_realtime_data(stock_code)
            
            display_price = ocr_current_price if ocr_current_price else (api_data["price"] if api_data else None)
            display_avg = ocr_avg_price if ocr_avg_price else (api_data["vwap"] if api_data else None)
            
            if api_data:
                self.name_label.setText(api_data["name"])
                
                deviation = (display_price - api_data["vwap"]) / api_data["vwap"] * 100 if display_price and api_data["vwap"] > 0 else 0
                
                if deviation >= 0:
                    dev_text = f"+{deviation:.2f}%"
                    color = "#e74c3c"
                else:
                    dev_text = f"{deviation:.2f}%"
                    color = "#27ae60"
                
                self.deviation_label.setText(dev_text)
                self.deviation_label.setStyleSheet(f"color: {color}; font-size: 22px; font-weight: bold;")
                
                ocr_str = f"{display_price:.2f}" if display_price else "--"
                api_str = f"{api_data['price']:.2f}" if api_data else "--"
                self.price_detail.setText(f"OCR: {ocr_str} | API: {api_str}")
                
                vwap_str = f"{api_data['vwap']:.2f}" if api_data else "--"
                dev_str = f"{deviation:+.2f}%" if display_price else "--%"
                self.vwap_label.setText(f"VWAP: {vwap_str} | 偏离: {dev_str}")
                
                signal_text = ""
                vol_status = ""
                if api_data["vol_ratio"]:
                    vr = api_data["vol_ratio"]
                    if vr > 1.5:
                        vol_status = f"放量{vr:.1f}x"
                    elif vr < 0.7:
                        vol_status = f"缩量{vr:.1f}x"
                    else:
                        vol_status = f"平量{vr:.1f}x"
                
                fs = api_data.get("flow_strength", 0)
                money_info = ""
                if fs > 5:
                    money_info = f"主力净买{fs:+.1f}%"
                elif fs < -5:
                    money_info = f"主力净卖{fs:+.1f}%"
                
                if abs(deviation) >= 2:
                    if deviation > 0:
                        signal_text = "📈 强势"
                    else:
                        signal_text = "📉 弱势"
                
                parts = [vol_status, money_info, signal_text]
                self.signal_label.setText(" | ".join([p for p in parts if p]))
                
                self.status_label.setText(f"更新: {datetime.now().strftime('%H:%M:%S')}")
            
        except Exception as e:
            log(f"更新异常: {e}")
            self.status_label.setText("异常")
    
    def open_settings(self):
        dialog = SettingsDialog(self.config, self)
        if dialog.exec_() == QDialog.Accepted:
            self.config = dialog.get_config()
            save_config(self.config)
            self.apply_config()
    
    def closeEvent(self, event):
        self.config["window_pos"] = {"x": self.x(), "y": self.y()}
        save_config(self.config)
        super().closeEvent(event)

class SettingsDialog(QDialog):
    def __init__(self, config, parent=None):
        super().__init__(parent)
        self.config = config.copy()
        self.setWindowTitle("设置")
        self.setFixedSize(380, 380)
        self.init_ui()
    
    def init_ui(self):
        layout = QVBoxLayout()
        layout.setSpacing(8)
        layout.setContentsMargins(20, 16, 20, 16)
        
        mode_group = QGroupBox("运行模式")
        mode_layout = QVBoxLayout()
        self.ocr_mode = QCheckBox("OCR 跟随模式 (自动识别同花顺当前股票)")
        self.ocr_mode.setChecked(self.config.get("mode") == "ocr")
        mode_layout.addWidget(self.ocr_mode)
        mode_group.setLayout(mode_layout)
        layout.addWidget(mode_group)
        
        manual_group = QGroupBox("手动模式 (关闭上方 OCR 模式生效)")
        manual_layout = QHBoxLayout()
        manual_layout.addWidget(QLabel("股票代码:"))
        self.code_edit = QLineEdit(self.config.get("stock_code", "603687"))
        manual_layout.addWidget(self.code_edit)
        manual_group.setLayout(manual_layout)
        layout.addWidget(manual_group)
        
        ocr_group = QGroupBox("OCR 区域设置 (包含股票名+均价+最新价)")
        ocr_layout = QVBoxLayout()
        
        reg = self.config.get("ocr_region", DEFAULT_CONFIG["ocr_region"])
        
        row1 = QHBoxLayout()
        row1.addWidget(QLabel("Top:"))
        self.top_edit = self._edit(str(reg["top"]))
        row1.addWidget(QLabel("Left:"))
        self.left_edit = self._edit(str(reg["left"]))
        row1.addWidget(QLabel("W:"))
        self.w_edit = self._edit(str(reg["width"]))
        row1.addWidget(QLabel("H:"))
        self.h_edit = self._edit(str(reg["height"]))
        ocr_layout.addLayout(row1)
        
        select_btn = QPushButton("📸 选择 OCR 区域")
        select_btn.clicked.connect(self.select_ocr_region)
        ocr_layout.addWidget(select_btn)
        
        test_btn = QPushButton("🧪 测试 OCR 识别效果")
        test_btn.clicked.connect(self.test_ocr)
        ocr_layout.addWidget(test_btn)
        
        ocr_group.setLayout(ocr_layout)
        layout.addWidget(ocr_group)
        
        interval_layout = QHBoxLayout()
        interval_layout.addWidget(QLabel("刷新间隔(ms):"))
        self.interval_edit = self._edit(str(self.config.get("update_interval", 700)))
        interval_layout.addWidget(self.interval_edit)
        interval_layout.addStretch()
        layout.addLayout(interval_layout)
        
        btn_layout = QHBoxLayout()
        save_btn = QPushButton("💾 保存并应用")
        save_btn.clicked.connect(self.accept)
        cancel_btn = QPushButton("取消")
        cancel_btn.clicked.connect(self.reject)
        btn_layout.addWidget(save_btn)
        btn_layout.addWidget(cancel_btn)
        layout.addLayout(btn_layout)
        
        self.setLayout(layout)
    
    def _edit(self, text):
        edit = QLineEdit(text)
        edit.setFixedWidth(55)
        return edit
    
    def select_ocr_region(self):
        dialog = RegionSelectDialog(self)
        if dialog.exec_() == QDialog.Accepted:
            region = dialog.get_region()
            self.top_edit.setText(str(region["top"]))
            self.left_edit.setText(str(region["left"]))
            self.w_edit.setText(str(region["width"]))
            self.h_edit.setText(str(region["height"]))
    
    def test_ocr(self):
        reg = {
            "top": int(self.top_edit.text()),
            "left": int(self.left_edit.text()),
            "width": int(self.w_edit.text()),
            "height": int(self.h_edit.text())
        }
        results = vision_ocr(reg)
        if results:
            parsed = parse_ocr_results(results)
            msg = f"""原始文本: {parsed['raw_text']}

识别结果:
  股票名: {parsed['name'] or '(未识别)'}
  股票代码: {parsed['code'] or '(未识别)'}
  均价: {parsed['avg_price'] or '(未识别)'}
  最新价: {parsed['current_price'] or '(未识别)'}

原始结果:"""
            for r in results:
                msg += f"\n  \"{r['text']}\" ({r['confidence']*100:.0f}%)"
            QMessageBox.information(self, "OCR 测试结果", msg)
        else:
            QMessageBox.warning(self, "OCR 测试", "未识别到任何文字\n\n请调整区域位置或大小")
    
    def get_config(self):
        self.config["mode"] = "ocr" if self.ocr_mode.isChecked() else "manual"
        self.config["stock_code"] = self.code_edit.text().strip()
        try:
            self.config["ocr_region"] = {
                "top": int(self.top_edit.text()),
                "left": int(self.left_edit.text()),
                "width": int(self.w_edit.text()),
                "height": int(self.h_edit.text())
            }
            self.config["update_interval"] = max(300, min(5000, int(self.interval_edit.text())))
        except ValueError:
            pass
        return self.config

class RegionSelectDialog(QDialog):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.selected_region = None
        self.is_dragging = False
        self.start_point = None
        self.current_rect = None
        
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
        self.setAttribute(Qt.WA_TranslucentBackground)
        
        screen = QApplication.primaryScreen()
        self.screen_geom = screen.availableGeometry()
        self.setGeometry(self.screen_geom)
        
        self.capture_screen()
    
    def capture_screen(self):
        with objc.autorelease_pool():
            display = Quartz.CGMainDisplayID()
            rect = Quartz.CGRectMake(
                self.screen_geom.left(), self.screen_geom.top(),
                self.screen_geom.width(), self.screen_geom.height()
            )
            self.cg_image = Quartz.CGDisplayCreateImageForRect(display, rect)
    
    def paintEvent(self, event):
        from PyQt5.QtGui import QPainter, QColor, QPen
        from PyQt5.QtCore import QRect
        painter = QPainter(self)
        
        w = int(self.screen_geom.width())
        h = int(self.screen_geom.height())
        
        painter.fillRect(0, 0, w, h, QColor(0, 0, 0, 120))
        
        painter.setPen(QColor(255, 200, 0))
        painter.setFont(QFont("Arial", 18, QFont.Bold))
        painter.drawText(20, 40, "拖动选择包含「股票名+均价+最新价」的区域")
        painter.drawText(20, 70, "按 Esc 取消 / 松开鼠标确认")
        
        if self.current_rect:
            x, y, rw, rh = self.current_rect
            rect = QRect(int(x), int(y), int(rw), int(rh))
            
            painter.setCompositionMode(QPainter.CompositionMode_Clear)
            painter.fillRect(rect, Qt.transparent)
            painter.setCompositionMode(QPainter.CompositionMode_SourceOver)
            
            pen = QPen(QColor(255, 80, 80), 3, Qt.SolidLine)
            painter.setPen(pen)
            painter.drawRect(rect)
            
            size_text = f"{int(rw)} x {int(rh)}"
            pen2 = QPen(QColor(255, 255, 255), 1)
            painter.setPen(pen2)
            painter.setFont(QFont("Arial", 12))
            painter.drawText(int(x) + 5, int(y) - 5, size_text)
        
        painter.end()
    
    def mousePressEvent(self, event):
        self.is_dragging = True
        self.start_point = event.pos()
        self.current_rect = (event.pos().x(), event.pos().y(), 0, 0)
    
    def mouseMoveEvent(self, event):
        if self.is_dragging and self.start_point:
            x1 = min(self.start_point.x(), event.pos().x())
            y1 = min(self.start_point.y(), event.pos().y())
            x2 = max(self.start_point.x(), event.pos().x())
            y2 = max(self.start_point.y(), event.pos().y())
            self.current_rect = (x1, y1, x2 - x1, y2 - y1)
            self.update()
    
    def mouseReleaseEvent(self, event):
        if self.is_dragging and self.start_point:
            end = event.pos()
            x1 = min(self.start_point.x(), end.x())
            y1 = min(self.start_point.y(), end.y())
            x2 = max(self.start_point.x(), end.x())
            y2 = max(self.start_point.y(), end.y())
            
            w, h = x2 - x1, y2 - y1
            if w < 20 or h < 10:
                w, h = 200, 55
                x1 -= 100
                y1 -= 27
            
            self.selected_region = {
                "top": int(y1 + self.screen_geom.top()),
                "left": int(x1 + self.screen_geom.left()),
                "width": int(w),
                "height": int(h)
            }
            self.accept()
    
    def keyPressEvent(self, event):
        if event.key() == Qt.Key_Escape:
            self.reject()
        elif event.key() == Qt.Key_Return or event.key() == Qt.Key_Enter:
            if self.selected_region:
                self.accept()
    
    def get_region(self):
        return self.selected_region or DEFAULT_CONFIG["ocr_region"]

def main():
    QApplication.setAttribute(Qt.AA_MacDontSwapCtrlAndMeta, True)
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    monitor = StockMonitor()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()
