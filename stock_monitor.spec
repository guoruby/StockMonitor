# -*- mode: python ; coding: utf-8 -*-
# onedir 模式 - macOS .app 推荐方式

block_cipher = None

a = Analysis(
    ['stock_monitor_api.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=[
        'PyQt5',
        'PyQt5.QtCore',
        'PyQt5.QtGui',
        'PyQt5.QtWidgets',
        'PyQt5.sip',
        'requests',
        'Quartz',
        'Vision',
        'objc',
        'Foundation',
        'AppKit'
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        'tkinter',
        'matplotlib',
        'scipy',
        'pandas',
        'unittest',
        'pydoc',
        'html'
    ],
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='StockMonitor',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    name='StockMonitor',
)

app = BUNDLE(
    coll,
    name='股票价格监控.app',
    icon=None,
    bundle_identifier='com.stockmonitor.app',
    info_plist={
        'NSHighResolutionCapable': True,
        'LSUIElement': False,
        'NSAppleEventsUsageDescription': '需要屏幕录制权限以识别股票价格',
        'NSScreenCaptureUsageDescription': '需要截取屏幕区域来识别同花顺中的股票名称和价格',
        'CFBundleShortVersionString': '2.0.0',
        'CFBundleVersion': '2.0.0',
        'LSMinimumSystemVersion': '10.13',
    },
)
