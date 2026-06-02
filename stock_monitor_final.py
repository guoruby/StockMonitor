#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
股票价格监控程序 - 最终版
功能：读取同花顺软件个股分时K线的均价和最新价，计算偏离比例并实时显示
"""

import sys
import json
import os
import re
import time
import mss
import numpy as np
import cv2
from datetime import datetime
from PyQt5.QtWidgets import (QApplication, QWidget, QLabel, QVBoxLayout,
                            QHBoxLayout, QPushButton, QDialog, QGraphicsView, QGraphicsScene, QGraphicsPixmapItem, QShortcut)
from PyQt5.QtCore import Qt, QTimer, QThread, pyqtSignal, QRectF, QPointF, QEvent
from PyQt5.QtGui import (QFont, QColor, QPalette, QMouseEvent, QImage, QPixmap,
                         QPainter, QPen, QBrush, QPainterPath, QKeySequence)

import pytesseract
import base64
import io
import requests
from PIL import Image
from pynput import keyboard



# 全局快捷键回调
_global_hotkey_callback = None

# 日志文件 - 按日期自动轮转
def get_log_file():
    """获取当天的日志文件路径"""
    return f"ocr_{datetime.now().strftime('%Y%m%d')}.log"

def log_ocr(message):
    """写入OCR日志（每天一个文件，自动覆盖）"""
    log_file = get_log_file()
    timestamp = datetime.now().strftime("%H:%M:%S")
    with open(log_file, 'a', encoding='utf-8') as f:
        f.write(f"[{timestamp}] {message}\n")





# 设置 Tesseract 路径
import os
os.environ['PATH'] = '/usr/local/bin:/usr/bin:/bin:' + os.environ.get('PATH', '')

def do_ocr(region):
    """使用Tesseract OCR进行识别"""
    try:
        import time
        start_time = time.time()

        # 检查Tesseract环境
        import shutil
        tesseract_path = shutil.which('tesseract')
        if not tesseract_path:
            log_ocr("[错误] 找不到tesseract命令，请安装: brew install tesseract")
            return None, None

        with mss.mss() as sct:
            screenshot = sct.grab(region)

        img = np.array(screenshot)
        img = cv2.cvtColor(img, cv2.COLOR_BGRA2RGB)

        # 图像预处理
        gray = cv2.cvtColor(img, cv2.COLOR_RGB2GRAY)
        # 二值化增强对比度
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        # 反转，黑字白底
        binary = cv2.bitwise_not(binary)

        # 使用Tesseract识别，指定完整路径
        custom_config = r'--oem 3 --psm 6 -c tessedit_char_whitelist=0123456789.:均价最新'
        text = pytesseract.image_to_string(binary, config=custom_config, lang='chi_sim')

        elapsed_time = time.time() - start_time
        log_ocr(f"耗时: {elapsed_time*1000:.1f}ms, Tesseract路径: {tesseract_path}, 识别结果: {text.strip()}")

        if text:
            # 精确匹配"均价"和"最新"
            avg_match = re.search(r'均价[:：\s]*([\d.]+)', text)
            current_match = re.search(r'最新[:：\s]*([\d.]+)', text)
            avg_price = float(avg_match.group(1)) if avg_match else None
            current_price = float(current_match.group(1)) if current_match else None
            return current_price, avg_price
        return None, None
    except Exception as e:
        log_ocr(f"异常: {e}")
        import traceback
        traceback.print_exc()
        return None, None


def do_ocr_siliconflow(region, api_key):
    """使用SiliconFlow API进行OCR识别"""
    try:
        import time
        start_time = time.time()

        with mss.mss() as sct:
            screenshot = sct.grab(region)

        img = np.array(screenshot)
        img = cv2.cvtColor(img, cv2.COLOR_BGRA2RGB)

        pil_img = Image.fromarray(img)
        buffer = io.BytesIO()
        pil_img.save(buffer, format='PNG')
        img_bytes = buffer.getvalue()
        base64_image = base64.b64encode(img_bytes).decode('utf-8')

        prompt = "请识别图片中的文字，按以下格式输出：股票代码(6位数字) 股票名称 均价:数字 最新:数字。如果图片中没有股票代码，只输出股票名称和其他信息。只输出这一行，不要其他内容。"

        url = "https://api.siliconflow.cn/v1/chat/completions"
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json"
        }
        payload = {
            "model": "PaddlePaddle/PaddleOCR-VL",
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "image_url",
                            "image_url": {
                                "url": f"data:image/png;base64,{base64_image}",
                                "detail": "low"
                            }
                        },
                        {
                            "type": "text",
                            "text": prompt
                        }
                    ]
                }
            ],
            "max_tokens": 100,
            "temperature": 0.1
        }

        response = requests.post(url, headers=headers, json=payload, timeout=0.6)
        if response.status_code != 200:
            log_ocr(f"SiliconFlow API错误: HTTP {response.status_code}, 响应: {response.text}")
        response.raise_for_status()
        result = response.json()

        text = result.get("choices", [{}])[0].get("message", {}).get("content", "").strip()

        elapsed_time = time.time() - start_time
        log_ocr(f"SiliconFlow耗时: {elapsed_time*1000:.1f}ms, 识别结果: {text}")

        if text:
            avg_match = re.search(r'均价[:：\s]*([\d.]+)', text)
            current_match = re.search(r'最新[:：\s]*([\d.]+)', text)
            avg_price = float(avg_match.group(1)) if avg_match else None
            current_price = float(current_match.group(1)) if current_match else None
            return current_price, avg_price
        return None, None
    except Exception as e:
        log_ocr(f"SiliconFlow异常: {e}")
        import traceback
        traceback.print_exc()
        return None, None




class OCRWorker:
    """OCR工作器 - 支持Tesseract和SiliconFlow API"""

    @staticmethod
    def run(region, ocr_type="tesseract", api_key=None):
        """运行OCR
        Returns:
            (current_price, avg_price)
        """
        if ocr_type == "siliconflow":
            if not api_key:
                log_ocr("[错误] SiliconFlow模式需要API Key")
                return None, None
            return do_ocr_siliconflow(region, api_key)
        else:
            return do_ocr(region)





class StockMonitor(QWidget):
    """股票价格监控器"""

    def __init__(self):
        super().__init__()

        # 设置窗口（有标题栏）
        self.setWindowFlags(Qt.Window)
        self.setAttribute(Qt.WA_MacAlwaysShowToolWindow, True)

        # 数据变量
        self.current_price = 0.0
        self.avg_price = 0.0
        self.deviation = 0.0
        self.deviation_percent = 0.0
        self.last_update_time = ""
        self.is_monitoring = False
        self.is_compact_mode = False  # 紧凑模式标志
        self.mouse_on_window = False  # 鼠标是否在窗口上
        self.ocr_fail_count = 0  # OCR连续失败次数
        self.is_circuit_breaker = False  # 是否处于熔断状态
        self.alert_blink_state = False  # 提醒闪烁状态
        self.alert_blink_timer = None  # 提醒闪烁定时器
        self.flash_timer_id = None  # 闪烁恢复定时器ID

        # 加载配置
        self.load_config()

        # 创建界面
        self.create_widgets()

        # 设置定时器
        self.timer = QTimer()
        self.timer.timeout.connect(self.update_price)

        # 设置系统级全局快捷键 Command+L
        self.setup_global_hotkey()

        # 设置主题
        self.set_theme()

        # 显示窗口
        self.show()
        self.raise_()
        self.activateWindow()
        self.ensure_visible()

    def ensure_visible(self):
        """确保窗口在可见区域"""
        screen = QApplication.primaryScreen()
        screen_geometry = screen.availableGeometry()
        
        # 获取窗口位置
        window_geometry = self.frameGeometry()
        
        # 如果窗口在屏幕外，移动到屏幕中心
        if not screen_geometry.intersects(window_geometry):
            x = (screen_geometry.width() - window_geometry.width()) // 2
            y = (screen_geometry.height() - window_geometry.height()) // 2
            self.move(x, y)
        
        # 确保窗口在最前面
        self.raise_()
        self.activateWindow()

    def setup_global_hotkey(self):
        """设置系统级全局快捷键"""
        global _global_hotkey_callback
        _global_hotkey_callback = self

        # 定义快捷键回调
        def on_activate():
            from PyQt5.QtCore import QTimer
            QTimer.singleShot(0, self.toggle_monitoring)

        # 监听 Command+L (Mac 上是 cmd_l)
        def on_press(key):
            try:
                if key == keyboard.Key.cmd_l or key == keyboard.Key.cmd_r:
                    self.cmd_pressed = True
                elif self.cmd_pressed and key == keyboard.KeyCode.from_char('l'):
                    on_activate()
            except AttributeError:
                pass

        def on_release(key):
            try:
                if key == keyboard.Key.cmd_l or key == keyboard.Key.cmd_r:
                    self.cmd_pressed = False
            except AttributeError:
                pass

        self.cmd_pressed = False
        self.listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        self.listener.start()

    def set_theme(self):
        """设置白色主题"""
        palette = QPalette()
        palette.setColor(QPalette.Window, QColor(255, 255, 255))
        palette.setColor(QPalette.WindowText, QColor(50, 50, 50))
        palette.setColor(QPalette.Base, QColor(250, 250, 250))
        palette.setColor(QPalette.AlternateBase, QColor(245, 245, 245))
        palette.setColor(QPalette.ToolTipBase, QColor(255, 255, 220))
        palette.setColor(QPalette.ToolTipText, QColor(50, 50, 50))
        palette.setColor(QPalette.Text, QColor(50, 50, 50))
        palette.setColor(QPalette.Button, QColor(240, 240, 240))
        palette.setColor(QPalette.ButtonText, QColor(50, 50, 50))
        palette.setColor(QPalette.BrightText, QColor(255, 0, 0))
        palette.setColor(QPalette.Link, QColor(0, 100, 200))
        palette.setColor(QPalette.Highlight, QColor(42, 130, 218))
        palette.setColor(QPalette.HighlightedText, QColor(0, 0, 0))
        self.setPalette(palette)
    
    def load_config(self):
        """加载配置"""
        config_file = "monitor_config.json"
        if os.path.exists(config_file):
            try:
                with open(config_file, 'r', encoding='utf-8') as f:
                    self.monitor_region = json.load(f)
            except:
                self.monitor_region = self.default_config()
        else:
            self.monitor_region = self.default_config()
        
        # 恢复窗口位置
        if 'window_pos' in self.monitor_region:
            pos = self.monitor_region['window_pos']
            self.move(pos['x'], pos['y'])
    
    def default_config(self):
        """默认配置"""
        return {
            'monitor_region': {'top': 0, 'left': 0, 'width': 200, 'height': 40},
            'ocr_type': 'tesseract',
            'api_key': '',
            'stock_code': ''
        }
    
    def create_widgets(self):
        """创建界面"""
        # 使用绝对布局，让偏离值标签位置固定
        self.setFixedSize(80, 60)  # 宽度增加10像素，高度减少

        # 偏离百分比显示 - 固定在顶部
        self.deviation_label = QLabel("--%")
        self.deviation_label.setFont(QFont("Arial", 12, QFont.Bold))
        self.deviation_label.setAlignment(Qt.AlignLeft | Qt.AlignVCenter)
        self.deviation_label.setStyleSheet("color: #333;")
        self.deviation_label.setGeometry(10, 0, 54, 16)  # 向右移动10px
        self.deviation_label.setParent(self)
        self.deviation_label.show()

        # 播放/暂停按钮 - 右上角
        from PyQt5.QtGui import QIcon
        self.toggle_btn = QPushButton()
        self.toggle_btn.setFixedSize(16, 16)
        self.toggle_btn.setGeometry(64, 0, 16, 16)
        self.toggle_btn.setParent(self)
        self.toggle_btn.show()
        self.toggle_btn.setStyleSheet("QPushButton { border: none; background: transparent; }")
        self.update_toggle_button_icon()
        self.toggle_btn.clicked.connect(self.toggle_monitoring)

        # 详情面板（默认隐藏）
        self.details_panel = QWidget()
        self.details_panel.setGeometry(0, 16, 80, 22)  # 调整位置和宽度
        self.details_panel.setParent(self)
        details_layout = QVBoxLayout()
        details_layout.setSpacing(0)
        details_layout.setContentsMargins(5, 0, 5, 0)
        details_layout.setContentsMargins(0, 0, 0, 0)

        # 最新价和均价在同一行
        price_layout = QHBoxLayout()
        self.current_price_label = QLabel("最新: --")
        self.current_price_label.setFont(QFont("Arial", 8))
        self.current_price_label.setStyleSheet("color: #666;")
        price_layout.addWidget(self.current_price_label)

        self.avg_price_label = QLabel("均价: --")
        self.avg_price_label.setFont(QFont("Arial", 8))
        self.avg_price_label.setStyleSheet("color: #666;")
        price_layout.addWidget(self.avg_price_label)
        details_layout.addLayout(price_layout)

        # 更新时间
        self.time_label = QLabel("--:--:--")
        self.time_label.setFont(QFont("Arial", 7))
        self.time_label.setStyleSheet("color: #999;")
        self.time_label.setAlignment(Qt.AlignCenter)
        details_layout.addWidget(self.time_label)

        self.details_panel.setLayout(details_layout)
        self.details_panel.setVisible(False)  # 默认隐藏

        # 按钮面板 - 只保留设置按钮
        self.button_panel = QWidget()
        self.button_panel.setGeometry(0, 38, 80, 22)  # 调整位置和宽度
        self.button_panel.setParent(self)
        button_layout = QHBoxLayout()
        button_layout.setSpacing(2)
        button_layout.setContentsMargins(0, 0, 0, 0)

        self.config_btn = QPushButton("设置")
        self.config_btn.setFont(QFont("Arial", 9))
        self.config_btn.setStyleSheet("""
            QPushButton {
                background-color: #f0f0f0;
                color: #333;
                border: 1px solid #ddd;
                padding: 2px 4px;
                border-radius: 2px;
            }
            QPushButton:hover {
                background-color: #e0e0e0;
            }
        """)
        self.config_btn.clicked.connect(self.open_config_window)
        button_layout.addWidget(self.config_btn)

        self.button_panel.setLayout(button_layout)
        self.button_panel.setVisible(True)

        # 设置鼠标跟踪以支持hover
        self.setMouseTracking(True)

    def update_toggle_button_icon(self):
        """更新播放/暂停按钮图标"""
        from PyQt5.QtGui import QIcon, QPainter, QPolygonF, QPen
        from PyQt5.QtCore import Qt, QPointF

        # 创建图标
        pixmap = QPixmap(16, 16)
        pixmap.fill(Qt.transparent)
        painter = QPainter(pixmap)

        if self.is_monitoring:
            # 暂停图标 (两条竖线) - 红色
            pen = QPen(QColor(255, 100, 100))
            pen.setWidth(3)
            painter.setPen(pen)
            painter.drawLine(5, 3, 5, 13)
            painter.drawLine(11, 3, 11, 13)
        else:
            # 播放图标 (三角形) - 红色
            painter.setPen(Qt.NoPen)
            painter.setBrush(QColor(255, 100, 100))
            triangle = QPolygonF([QPointF(4, 3), QPointF(4, 13), QPointF(13, 8)])
            painter.drawPolygon(triangle)

        painter.end()
        self.toggle_btn.setIcon(QIcon(pixmap))
        self.toggle_btn.setStyleSheet("QPushButton { border: none; background: transparent; }")

    def open_config_window(self):
        """打开配置窗口"""
        dialog = ConfigDialog(self.monitor_region, self)
        if dialog.exec_() == QDialog.Accepted:
            self.monitor_region = dialog.get_config()
            self.save_config()
    
    def save_config(self):
        """保存配置"""
        config_file = "monitor_config.json"
        # 保存窗口位置
        self.monitor_region['window_pos'] = {
            'x': self.x(),
            'y': self.y()
        }
        with open(config_file, 'w', encoding='utf-8') as f:
            json.dump(self.monitor_region, f, ensure_ascii=False, indent=2)

    def toggle_monitoring(self):
        """切换监控"""
        self.is_monitoring = not self.is_monitoring

        # 保存当前位置
        current_pos = self.pos()

        if self.is_monitoring:
            self.timer.start(700)  # 500ms执行一次

            # 进入紧凑模式：隐藏详情和按钮，隐藏标题栏
            self.is_compact_mode = True
            self.details_panel.setVisible(False)
            self.button_panel.setVisible(False)
            # 切换到无边框模式
            self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint)
            # 调整窗口大小，只显示第一行
            self.setFixedSize(80, 16)
            self.show()
            # 恢复位置
            self.move(current_pos)
        else:
            self.timer.stop()

            # 退出紧凑模式：显示所有内容，恢复标题栏，不置顶
            self.is_compact_mode = False
            self.details_panel.setVisible(True)
            self.button_panel.setVisible(True)
            # 切换到普通窗口模式（不置顶）
            self.setWindowFlags(Qt.Window)
            # 恢复完整高度
            self.setFixedSize(80, 60)
            self.show()
            # 恢复位置
            self.move(current_pos)

        # 更新播放/暂停按钮图标
        self.update_toggle_button_icon()

    def mousePressEvent(self, event):
        """鼠标按下事件"""
        if event.button() == Qt.LeftButton:
            self.drag_position = event.globalPos() - self.frameGeometry().topLeft()
            # 如果在紧凑模式下点击，显示详情
            if self.is_compact_mode and self.mouse_on_window:
                self.mouse_on_window = True  # 确保标记为鼠标在窗口上

    def mouseMoveEvent(self, event):
        """鼠标移动事件（拖动窗口）"""
        if event.buttons() == Qt.LeftButton and hasattr(self, 'drag_position'):
            self.move(event.globalPos() - self.drag_position)
            # 拖动结束时保存位置（节流，不用每次移动都保存）
            if not hasattr(self, '_save_timer'):
                self._save_timer = QTimer.singleShot(500, self.save_config)

    def enterEvent(self, event):
        """鼠标进入事件 - 在紧凑模式下显示详情"""
        self.mouse_on_window = True
        if self.is_compact_mode:
            # 延迟展开，避免与按钮点击冲突
            QTimer.singleShot(50, self._expand_window)

    def leaveEvent(self, event):
        """鼠标离开事件 - 在紧凑模式下隐藏详情"""
        self.mouse_on_window = False
        if self.is_compact_mode:
            self.details_panel.setVisible(False)
            self.button_panel.setVisible(False)
            current_pos = self.pos()
            self.setFixedSize(80, 16)
            self.move(current_pos.x(), current_pos.y())

    def _expand_window(self):
        """展开窗口（延迟调用）"""
        if self.mouse_on_window and self.is_compact_mode:
            self.details_panel.setVisible(True)
            self.button_panel.setVisible(True)
            current_pos = self.pos()
            self.setFixedSize(80, 60)
            self.move(current_pos.x(), current_pos.y())

    def showEvent(self, event):
        """窗口显示事件"""
        super().showEvent(event)
        # 检查鼠标是否在窗口上，如果是则显示详情
        self.check_mouse_position()

    def changeEvent(self, event):
        """窗口状态改变事件"""
        super().changeEvent(event)
        # 窗口激活时检查鼠标位置
        if event.type() == QEvent.ActivationChange and self.isActiveWindow():
            self.check_mouse_position()

    def check_mouse_position(self):
        """检查鼠标是否在窗口上"""
        if self.is_compact_mode:
            cursor_pos = self.mapFromGlobal(self.cursor().pos())
            if 0 <= cursor_pos.x() < self.width() and 0 <= cursor_pos.y() < self.height():
                self.mouse_on_window = True
                # 延迟展开，避免冲突
                QTimer.singleShot(50, self._expand_window)

    def update_price(self):
        """更新价格"""
        try:
            # 如果处于熔断状态，直接返回
            if self.is_circuit_breaker:
                return

            # 获取监控区域
            region = self.monitor_region.get('monitor_region', {'top': 0, 'left': 0, 'width': 200, 'height': 40})

            # 获取OCR配置
            ocr_type = self.monitor_region.get('ocr_type', 'tesseract')
            api_key = self.monitor_region.get('api_key', '')

            # 直接在主线程调用OCR
            current_price, avg_price = OCRWorker.run(region, ocr_type=ocr_type, api_key=api_key)

            # 识别失败时增加失败计数
            if not current_price or not avg_price or avg_price <= 0:
                self.ocr_fail_count += 1
                print(f"[熔断] OCR失败次数: {self.ocr_fail_count}/3")

                # 停止之前的闪烁提醒
                self.stop_alert_blink()

                # 连续3次失败，触发熔断
                if self.ocr_fail_count >= 3:
                    self.deviation_label.setText("熔断中")
                    self.deviation_label.setStyleSheet("background-color: #cccccc; color: #666666; font-size: 10px; font-weight: bold;")
                    self.is_circuit_breaker = True
                    self.ocr_fail_count = 0
                    print(f"[熔断] 触发熔断，暂停5秒")

                    # 5秒后恢复
                    QTimer.singleShot(5000, self.recover_from_circuit_breaker)
                else:
                    self.deviation_label.setText("识别失败")
                    self.deviation_label.setStyleSheet("background-color: #cccccc; color: #666666; font-size: 10px; font-weight: bold;")
                return

            # 识别成功，重置失败计数
            if self.ocr_fail_count > 0:
                print(f"[熔断] OCR成功，重置失败计数")
            self.ocr_fail_count = 0

            self.current_price = current_price
            self.avg_price = avg_price
            self.deviation = current_price - avg_price
            self.deviation_percent = (self.deviation / avg_price) * 100
            self.update_display()
        except Exception:
            # 快速失败，不处理
            pass

    def recover_from_circuit_breaker(self):
        """从熔断中恢复"""
        self.is_circuit_breaker = False
        print(f"[熔断] 熔断结束，恢复OCR")

    def update_display(self):
        """更新显示"""
        if self.deviation_percent >= 0:
            color = "#ff0000"
            text = f"+{self.deviation_percent:.2f}%"
        else:
            color = "#00aa00"
            text = f"{self.deviation_percent:.2f}%"
        
        self.deviation_label.setText(text)

        # 更新详情面板
        self.current_price_label.setText(f"最新: {self.current_price:.2f}")
        self.avg_price_label.setText(f"均价: {self.avg_price:.2f}")

        # 格式化时间
        self.time_label.setText(datetime.now().strftime("%H:%M:%S"))

        # 检查偏离幅度，超过4%开始剧烈闪烁提醒
        if abs(self.deviation_percent) >= 4.0:
            self.start_alert_blink()
        else:
            self.stop_alert_blink()

        # 更新指示效果：偏离值闪烁一下
        self.flash_deviation_label(color)

    def flash_deviation_label(self, color):
        """更新时柔和提示效果"""
        # 取消之前的闪烁定时器
        if hasattr(self, 'flash_timer') and self.flash_timer:
            try:
                self.flash_timer.stop()
            except:
                pass

        # 直接设置最终颜色，不再闪烁
        self.deviation_label.setStyleSheet(f"background-color: #ffffff; color: {color}; font-size: 12px; font-weight: bold;")

    def start_alert_blink(self):
        """开始提醒震动（窗口轻微抖动提醒）"""
        # 如果已经在闪烁，不重复启动
        if self.alert_blink_timer and self.alert_blink_timer.isActive():
            return

        # 保存原始位置
        self.original_pos = self.pos()
        self.shake_step = 0

        def shake():
            # 震动偏移模式
            offsets = [(1, 1), (-1, -1), (1, -1), (-1, 1), (0, 0)]
            dx, dy = offsets[self.shake_step % len(offsets)]
            self.move(self.original_pos.x() + dx, self.original_pos.y() + dy)
            self.shake_step += 1

        # 每100ms震动一次
        self.alert_blink_timer = QTimer()
        self.alert_blink_timer.timeout.connect(shake)
        self.alert_blink_timer.start(100)

    def stop_alert_blink(self):
        """停止提醒震动"""
        if self.alert_blink_timer:
            self.alert_blink_timer.stop()
            self.alert_blink_timer = None
            self.alert_blink_state = False
            # 恢复原始位置
            if hasattr(self, 'original_pos'):
                self.move(self.original_pos)


class ConfigDialog(QDialog):
    """配置区域对话框"""

    def __init__(self, config, parent=None):
        # 先设置窗口标志，再调用父类构造（无边框以移除红绿按钮）
        flags = Qt.FramelessWindowHint | Qt.Dialog | Qt.WindowStaysOnTopHint | Qt.NoDropShadowWindowHint
        super().__init__(parent, flags)
        self.setAttribute(Qt.WA_TranslucentBackground, False)  # 确保不透明
        self.config = config.copy()
        self.init_ui()
        self.update_preview()

    def init_ui(self):
        """初始化界面 - 小窗口，无红绿按钮"""
        self.setWindowTitle("设置监控区域")
        self.setStyleSheet("background-color: white;")  # 白色背景
        self.set_theme()

        layout = QVBoxLayout()
        layout.setContentsMargins(15, 15, 15, 15)
        layout.setSpacing(10)  # 减少组件间距

        # 说明
        info = QLabel("选择包含\"均价\"和\"最新\"的监控区域")
        info.setStyleSheet("color: #2196F3; font-size: 11px; padding: 6px; background-color: #f5f5f5; border-radius: 4px;")
        layout.addWidget(info)

        # 预览
        self.preview_label = QLabel()
        self.preview_label.setAlignment(Qt.AlignLeft)
        self.preview_label.setMinimumHeight(100)  # 减少高度
        self.preview_label.setStyleSheet("background-color: #fafafa; border: 1px solid #e0e0e0; border-radius: 4px; color: #333; padding: 8px;")
        layout.addWidget(self.preview_label)

        # OCR设置
        ocr_layout = QHBoxLayout()
        ocr_label = QLabel("OCR引擎:")
        ocr_label.setFont(QFont("Arial", 10))
        ocr_layout.addWidget(ocr_label)

        from PyQt5.QtWidgets import QComboBox, QLineEdit
        self.ocr_type_combo = QComboBox()
        self.ocr_type_combo.setFont(QFont("Arial", 10))
        self.ocr_type_combo.addItem("Tesseract (本地)")
        self.ocr_type_combo.addItem("SiliconFlow (API)")
        current_ocr_type = self.config.get('ocr_type', 'tesseract')
        if current_ocr_type == 'siliconflow':
            self.ocr_type_combo.setCurrentIndex(1)
        self.ocr_type_combo.setStyleSheet("""
            QComboBox {
                background-color: #fafafa;
                border: 1px solid #e0e0e0;
                border-radius: 4px;
                padding: 4px 8px;
            }
        """)
        ocr_layout.addWidget(self.ocr_type_combo)
        layout.addLayout(ocr_layout)

        # API Key输入
        api_key_layout = QHBoxLayout()
        api_key_label = QLabel("API Key:")
        api_key_label.setFont(QFont("Arial", 10))
        api_key_layout.addWidget(api_key_label)

        self.api_key_input = QLineEdit()
        self.api_key_input.setFont(QFont("Arial", 10))
        self.api_key_input.setPlaceholderText("输入SiliconFlow API Key")
        self.api_key_input.setText(self.config.get('api_key', ''))
        self.api_key_input.setStyleSheet("""
            QLineEdit {
                background-color: #fafafa;
                border: 1px solid #e0e0e0;
                border-radius: 4px;
                padding: 4px 8px;
            }
        """)
        api_key_layout.addWidget(self.api_key_input)
        layout.addLayout(api_key_layout)

        # 股票代码输入
        stock_code_layout = QHBoxLayout()
        stock_code_label = QLabel("股票代码:")
        stock_code_label.setFont(QFont("Arial", 10))
        stock_code_layout.addWidget(stock_code_label)

        self.stock_code_input = QLineEdit()
        self.stock_code_input.setFont(QFont("Arial", 10))
        self.stock_code_input.setPlaceholderText("如 000001")
        self.stock_code_input.setText(self.config.get('stock_code', ''))
        self.stock_code_input.setStyleSheet("""
            QLineEdit {
                background-color: #fafafa;
                border: 1px solid #e0e0e0;
                border-radius: 4px;
                padding: 4px 8px;
            }
        """)
        stock_code_layout.addWidget(self.stock_code_input)
        layout.addLayout(stock_code_layout)

        # 按钮区
        button_layout = QHBoxLayout()

        # 设置区域按钮
        self.monitor_btn = QPushButton("设置监控区域")
        self.monitor_btn.setFont(QFont("Arial", 10))
        self.monitor_btn.setMinimumHeight(28)
        self.monitor_btn.setStyleSheet("""
            QPushButton {
                background-color: #2196F3;
                color: white;
                border: none;
                padding: 5px 10px;
                border-radius: 4px;
            }
            QPushButton:hover {
                background-color: #1976D2;
            }
            QPushButton:pressed {
                background-color: #1565C0;
            }
        """)
        self.monitor_btn.clicked.connect(self.select_monitor_region)
        button_layout.addWidget(self.monitor_btn)

        # 关闭
        self.close_btn = QPushButton("关闭")
        self.close_btn.setFont(QFont("Arial", 10))
        self.close_btn.setMinimumHeight(28)
        self.close_btn.setStyleSheet("""
            QPushButton {
                background-color: #757575;
                color: white;
                border: none;
                padding: 5px 10px;
                border-radius: 4px;
            }
            QPushButton:hover {
                background-color: #616161;
            }
            QPushButton:pressed {
                background-color: #424242;
            }
        """)
        self.close_btn.clicked.connect(self.accept)
        button_layout.addWidget(self.close_btn)

        layout.addLayout(button_layout)
        self.setLayout(layout)

        # 在布局完成后设置固定大小
        self.setFixedSize(450, 250)  # 固定大小，减少留白

    def set_theme(self):
        """设置主题 - 白色背景"""
        palette = QPalette()
        palette.setColor(QPalette.Window, QColor(255, 255, 255))
        palette.setColor(QPalette.WindowText, QColor(0, 0, 0))
        self.setPalette(palette)

    def update_preview(self):
        """更新预览"""
        monitor_region = self.config.get('monitor_region', {})

        if monitor_region:
            text = f"""
            <h3>当前配置:</h3>
            <p><b>监控区域:</b> X={monitor_region['left']}, Y={monitor_region['top']}, 大小={monitor_region['width']}x{monitor_region['height']}</p>
            <p style='color: #2196F3'>监控区域已设置</p>
            """
        else:
            text = "<h3>当前配置:</h3><p style='color: #FFA500'>监控区域未设置</p>"

        self.preview_label.setText(text)

    def select_monitor_region(self):
        """选择监控区域"""
        dialog = SelectRegionDialog(self.config, region_type=None, parent=self)
        if dialog.exec_() == QDialog.Accepted:
            region = dialog.get_region()
            self.config['monitor_region'] = region
            self.save_config()
            self.update_preview()

    def save_config(self):
        """保存配置"""
        # 保存OCR设置
        from PyQt5.QtWidgets import QComboBox
        if self.ocr_type_combo.currentIndex() == 1:
            self.config['ocr_type'] = 'siliconflow'
        else:
            self.config['ocr_type'] = 'tesseract'
        self.config['api_key'] = self.api_key_input.text()
        self.config['stock_code'] = self.stock_code_input.text().strip()

        config_file = "monitor_config.json"
        with open(config_file, 'w', encoding='utf-8') as f:
            json.dump(self.config, f, ensure_ascii=False, indent=2)

    def get_config(self):
        """获取配置"""
        # 确保返回前保存OCR设置
        if self.ocr_type_combo.currentIndex() == 1:
            self.config['ocr_type'] = 'siliconflow'
        else:
            self.config['ocr_type'] = 'tesseract'
        self.config['api_key'] = self.api_key_input.text()
        self.config['stock_code'] = self.stock_code_input.text().strip()
        return self.config


class SelectRegionDialog(QDialog):
    """选择区域对话框（全屏截图）"""

    def __init__(self, config=None, region_type=None, parent=None):
        # 先设置窗口标志，再调用父类构造（全屏、无边框、置顶）
        flags = Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        super().__init__(parent, flags)
        
        self.regions = config.copy() if config else {}
        self.region_type = region_type  # 'current_price_region' 或 'avg_price_region'
        self.is_dragging = False
        self.is_resizing = False
        self.resize_handle = None  # 'tl', 'tr', 'bl', 'br', 't', 'b', 'l', 'r'
        self.start_pos = None
        self.start_rect = None
        self.current_rect = None
        self.size_text = None
        self.selected_region = None

        # 手柄大小
        self.handle_size = 10

        # 放大镜相关
        self.magnifier_size = 150  # 放大镜大小
        self.magnifier_zoom = 3  # 放大倍数
        self.magnifier_item = None
        self.magnifier_border = None

        # 根据区域类型设置颜色
        if self.region_type == 'current_price_region':
            self.region_color = QColor(0, 255, 0, 100)  # 绿色半透明
            self.region_border_color = QColor(0, 255, 0)  # 绿色
            self.instruction_text = "拖拽选择[最新价]区域，点击矩形内可拖动，按Enter确认"
        elif self.region_type == 'avg_price_region':
            self.region_color = QColor(0, 0, 255, 100)  # 蓝色半透明
            self.region_border_color = QColor(0, 0, 255)  # 蓝色
            self.instruction_text = "拖拽选择[均价]区域，点击矩形内可拖动，按Enter确认"
        else:
            # 通用监控区域
            self.region_color = QColor(255, 165, 0, 100)  # 橙色半透明
            self.region_border_color = QColor(255, 165, 0)  # 橙色
            self.instruction_text = "拖拽选择包含\"均价\"和\"最新\"的监控区域，点击矩形内可拖动，按Enter确认"
        # 初始化UI
        self.init_ui()

    def init_ui(self):
        """初始化 - 全屏白色背景"""
        try:
            # 白色背景
            self.setStyleSheet("background-color: white;")

            # 使用mss获取屏幕信息，确保一致性
            with mss.mss() as sct:
                # 获取主显示器
                monitor = sct.monitors[1]  # monitors[0]是所有显示器，monitors[1]是主显示器
                self.screen_rect = monitor

                # 截图
                screenshot = sct.grab(monitor)

                # 使用numpy数组处理
                img_np = np.array(screenshot)
                img_np = cv2.cvtColor(img_np, cv2.COLOR_BGRA2RGB)

                # 计算缩放比例（Retina屏幕通常是2x）
                self.scale_factor = screenshot.width / monitor['width']

                # 如果是Retina屏幕，需要缩放图像到逻辑像素大小
                if self.scale_factor > 1:
                    logical_width = int(monitor['width'])
                    logical_height = int(monitor['height'])
                    img_np = cv2.resize(img_np, (logical_width, logical_height), interpolation=cv2.INTER_AREA)

                # 转QImage
                height, width, channel = img_np.shape
                bytes_per_line = 3 * width
                q_img = QImage(img_np.data, width, height, bytes_per_line, QImage.Format_RGB888)
                self.pixmap = QPixmap.fromImage(q_img)

                # 设置窗口几何信息（全屏）
                self.setGeometry(monitor['left'], monitor['top'], monitor['width'], monitor['height'])
                self.setFixedSize(monitor['width'], monitor['height'])  # 强制固定大小

            # 创建视图
            layout = QVBoxLayout()
            layout.setContentsMargins(0, 0, 0, 0)

            self.view = QGraphicsView(self)
            self.view.setRenderHint(QPainter.Antialiasing)
            self.view.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
            self.view.setVerticalScrollBarPolicy(Qt.ScrollBarAlwaysOff)

            self.scene = QGraphicsScene(self)
            self.scene.setSceneRect(0, 0, self.screen_rect['width'], self.screen_rect['height'])
            self.view.setScene(self.scene)

            # 添加截图
            self.scene.addPixmap(self.pixmap)

            # 创建放大镜
            self.create_magnifier()

            # 绘制现有区域
            self.draw_existing_regions()

            # 提示
            self.instruction_label = self.scene.addText(self.instruction_text)
            self.instruction_label.setDefaultTextColor(QColor(255, 140, 0))  # 深橙色，白色背景可见
            font = QFont("Arial", 24, QFont.Bold)
            self.instruction_label.setFont(font)
            self.instruction_label.setPos(self.screen_rect['width'] // 2 - 250, 50)

            # 快捷键提示
            self.hint_label = self.scene.addText("Esc=取消，Enter=确认，点击矩形外重新选择")
            self.hint_label.setDefaultTextColor(QColor(100, 100, 100))  # 深灰色
            font = QFont("Arial", 14)
            self.hint_label.setFont(font)
            self.hint_label.setPos(50, self.screen_rect['height'] - 50)

            layout.addWidget(self.view)
            self.setLayout(layout)

            # 安装事件过滤器
            self.view.viewport().installEventFilter(self)
            self.view.setMouseTracking(True)
            self.view.setFocusPolicy(Qt.StrongFocus)
        except Exception as e:
            print(f"[错误] 初始化区域选择对话框失败: {e}")
            import traceback
            traceback.print_exc()

    def create_magnifier(self):
        """创建放大镜"""
        # 创建放大镜边框
        self.magnifier_border = self.scene.addRect(
            0, 0, self.magnifier_size, self.magnifier_size,
            QPen(QColor(255, 255, 255), 3),
            QBrush(QColor(0, 0, 0, 200))
        )
        self.magnifier_border.setZValue(100)  # 确保在最上层
        self.magnifier_border.setVisible(False)

        # 创建放大镜图像
        self.magnifier_item = self.scene.addPixmap(QPixmap())
        self.magnifier_item.setZValue(101)
        self.magnifier_item.setVisible(False)

    def update_magnifier(self, scene_pos):
        """更新放大镜位置和内容"""
        if not self.magnifier_border or not self.magnifier_item:
            return

        # 计算放大镜位置（直接跟随鼠标，让鼠标在放大镜中心）
        x = scene_pos.x() - self.magnifier_size // 2
        y = scene_pos.y() - self.magnifier_size // 2

        # 确保放大镜不超出屏幕
        if x < 0:
            x = 0
        if y < 0:
            y = 0
        if x + self.magnifier_size > self.screen_rect['width']:
            x = self.screen_rect['width'] - self.magnifier_size
        if y + self.magnifier_size > self.screen_rect['height']:
            y = self.screen_rect['height'] - self.magnifier_size

        # 更新边框位置
        self.magnifier_border.setRect(x, y, self.magnifier_size, self.magnifier_size)
        self.magnifier_border.setVisible(True)

        # 截取鼠标位置周围的图像（确保鼠标位置在放大镜中心）
        zoom_size = self.magnifier_size // self.magnifier_zoom
        zoom_x = int(max(0, min(scene_pos.x() - zoom_size // 2, self.screen_rect['width'] - zoom_size)))
        zoom_y = int(max(0, min(scene_pos.y() - zoom_size // 2, self.screen_rect['height'] - zoom_size)))

        # 从原始pixmap截取并缩放
        zoomed_pixmap = self.pixmap.copy(zoom_x, zoom_y, zoom_size, zoom_size).scaled(
            self.magnifier_size, self.magnifier_size,
            Qt.KeepAspectRatioByExpanding, Qt.SmoothTransformation
        )

        self.magnifier_item.setPixmap(zoomed_pixmap)
        self.magnifier_item.setPos(x, y)
        self.magnifier_item.setVisible(True)

    def hide_magnifier(self):
        """隐藏放大镜"""
        if self.magnifier_border:
            self.magnifier_border.setVisible(False)
        if self.magnifier_item:
            self.magnifier_item.setVisible(False)

    def draw_existing_regions(self):
        """绘制现有区域"""
        # 绘制已设置的监控区域
        if 'monitor_region' in self.regions:
            region = self.regions['monitor_region']
            rect = QRectF(region['left'], region['top'], region['width'], region['height'])
            self.scene.addRect(rect, QPen(QColor(255, 165, 0, 150), 2), QBrush(QColor(255, 165, 0, 50)))
    
    def eventFilter(self, source, event):
        """事件过滤器"""
        if source == self.view.viewport():
            if event.type() == QMouseEvent.MouseButtonPress:
                return self.handle_mouse_press(event)
            elif event.type() == QMouseEvent.MouseMove:
                return self.handle_mouse_move(event)
            elif event.type() == QMouseEvent.MouseButtonRelease:
                return self.handle_mouse_release(event)
            elif event.type() == QEvent.KeyPress:
                return self.handle_key_press(event)
        
        return super().eventFilter(source, event)
    
    def handle_mouse_press(self, event):
        """处理鼠标按下事件"""
        pos = self.view.mapToScene(event.pos())

        # 如果已经有选择区域，在矩形内拖动，在矩形外创建新区域
        if self.selected_region is not None and self.current_rect:
            rect = self.current_rect.rect()
            if rect.contains(pos):
                # 在矩形内，准备拖动
                self.is_dragging = True
                self.start_pos = pos
                self.start_rect = rect
                return True
            else:
                # 在矩形外，删除旧矩形并创建新区域
                self.scene.removeItem(self.current_rect)
                if self.size_text:
                    self.scene.removeItem(self.size_text)
                    self.size_text = None
                self.selected_region = None
                self.start_rect = None

        self.is_dragging = True
        self.start_pos = pos
        self.start_rect = None

        # 创建选择框
        self.current_rect = self.scene.addRect(
            self.start_pos.x(), self.start_pos.y(), 0, 0,
            QPen(self.region_border_color, 2),
            QBrush(self.region_color)
        )

        # 创建大小显示文本
        self.size_text = self.scene.addText("0 x 0")
        self.size_text.setDefaultTextColor(QColor(255, 255, 255))
        font = QFont("Arial", 14, QFont.Bold)
        self.size_text.setFont(font)

        return True

    def handle_mouse_move(self, event):
        """处理鼠标移动事件"""
        # 更新放大镜
        pos = self.view.mapToScene(event.pos())
        self.update_magnifier(pos)

        if not self.is_dragging or self.current_rect is None:
            return False

        # 计算矩形
        x = min(self.start_pos.x(), pos.x())
        y = min(self.start_pos.y(), pos.y())
        width = abs(pos.x() - self.start_pos.x())
        height = abs(pos.y() - self.start_pos.y())

        # 更新选择框
        self.current_rect.setRect(x, y, width, height)

        # 更新大小文本
        if self.size_text:
            self.size_text.setPlainText(f"{int(width)} x {int(height)}")
            self.size_text.setPos(x + 5, y - 25)

        return True
    
    def handle_mouse_release(self, event):
        """处理鼠标释放事件"""
        # 获取鼠标位置
        pos = self.view.mapToScene(event.pos())
        
        # 如果正在拖拽且有矩形，使用拖拽的矩形
        if self.is_dragging and self.current_rect is not None:
            self.is_dragging = False
            
            # 获取最终矩形
            rect = self.current_rect.rect()
            x, y = rect.x(), rect.y()
            width, height = rect.width(), rect.height()
            
            # 确保区域不为空
            if width < 10 or height < 10:
                # 如果区域太小，使用默认大小
                width, height = 100, 30
                x = self.start_pos.x() - width // 2
                y = self.start_pos.y() - height // 2
                self.current_rect.setRect(x, y, width, height)
            
            # 移除大小文本
            if self.size_text:
                self.scene.removeItem(self.size_text)
                self.size_text = None
            
            self.finalize_selection(x, y, width, height)
            return True

        # 如果没有在拖拽，则创建默认大小的区域（点击选择）
        if not self.is_dragging and self.selected_region is None:
            default_width, default_height = 100, 30

            x = pos.x() - default_width // 2
            y = pos.y() - default_height // 2

            # 绘制矩形
            self.current_rect = self.scene.addRect(
                x, y, default_width, default_height,
                QPen(self.region_border_color, 2),
                QBrush(self.region_color)
            )

            self.finalize_selection(x, y, default_width, default_height)
            return True

        return False

    def handle_key_press(self, event):
        """处理键盘事件"""
        if event.key() == Qt.Key_Escape:
            self.hide_magnifier()
            self.reject()
            return True
        elif event.key() == Qt.Key_Enter or event.key() == Qt.Key_Return:
            # 如果有矩形但没有确认，先确认
            if self.current_rect and not self.selected_region:
                rect = self.current_rect.rect()
                self.finalize_selection(rect.x(), rect.y(), rect.width(), rect.height())
            # 如果已确认，直接关闭
            elif self.selected_region:
                self.accept()
            return True

        return False

    def keyPressEvent(self, event):
        """直接处理键盘事件"""
        if event.key() == Qt.Key_Escape:
            self.hide_magnifier()
            self.reject()
            event.accept()
        elif event.key() == Qt.Key_Enter or event.key() == Qt.Key_Return:
            # 如果有矩形但没有确认，先确认
            if self.current_rect and not self.selected_region:
                rect = self.current_rect.rect()
                self.finalize_selection(rect.x(), rect.y(), rect.width(), rect.height())
                self.hide_magnifier()
            # 如果已确认，直接关闭
            elif self.selected_region:
                self.hide_magnifier()
                self.accept()
            event.accept()
        else:
            super().keyPressEvent(event)

    def finalize_selection(self, x, y, width, height):
        """完成当前区域选择"""
        # 保存选择的区域（加上屏幕偏移）
        self.selected_region = {
            'top': int(y + self.screen_rect['top']),
            'left': int(x + self.screen_rect['left']),
            'width': int(width),
            'height': int(height)
        }

        # 更新提示
        self.instruction_label.setPlainText("设置完成！点击任意处关闭")
        self.hide_magnifier()

    def get_region(self):
        """获取选择的区域"""
        return self.selected_region

    def get_regions(self):
        """获取所有区域（兼容旧版本）"""
        return self.regions


def main():
    """主函数"""
    # Mac 下确保 Command 键正常工作
    QApplication.setAttribute(Qt.AA_MacDontSwapCtrlAndMeta, True)
    app = QApplication(sys.argv)
    app.setStyle('Fusion')

    monitor = StockMonitor()

    # 定位到截图区域的右边，和偏离值那行对齐
    region = monitor.monitor_region.get('monitor_region', {'top': 300, 'left': 300, 'width': 200, 'height': 40})
    monitor.move(region['left'] + region['width'], region['top'])  # -16 是标题栏高度

    sys.exit(app.exec_())


if __name__ == "__main__":
    main()