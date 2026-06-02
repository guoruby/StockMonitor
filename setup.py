"""
股票价格监控 - macOS 应用程序打包配置
"""
from setuptools import setup
import os

APP = ['stock_monitor_final.py']
DATA_FILES = []
OPTIONS = {
    'argv_emulation': False,
    'plist': {
        'CFBundleName': '股票价格监控',
        'CFBundleDisplayName': '股票价格监控',
        'CFBundleGetInfoString': '股票价格偏离监控工具',
        'CFBundleIdentifier': 'com.monitorprice.stockmonitor',
        'CFBundleVersion': '1.0.0',
        'CFBundleShortVersionString': '1.0.0',
        'NSHumanReadableCopyright': 'Copyright © 2026',
        'NSHighResolutionCapable': True,
        'NSPrincipalClass': 'NSApplication',
        'NSAppleScriptEnabled': False,
        'LSBackgroundOnly': False,
        'LSUIElement': False,
        'NSRequiresAquaSystemAppearance': False,
    },
    'includes': [
        'PyQt5.QtCore',
        'PyQt5.QtGui',
        'PyQt5.QtWidgets',
        'PyQt5.sip',
        'cv2',
        'numpy',
        'numpy.core._multiarray_umath',
        'numpy.core._multiarray_tests',
        'numpy.linalg._umath_linalg',
        'numpy.fft._pocketfft_internal',
        'numpy.random.mtrand',
        'numpy.random._generator',
        'numpy.random.bit_generator',
        'PIL',
        'PIL._imaging',
        'mss',
        'pytesseract'
    ],
    'excludes': [
        'tkinter',
        'matplotlib',
        'scipy',
        'pandas',
        'test',
        'unittest',
    ],
    'iconfile': None,
    'strip': False,
    'optimize': 0,
}

setup(
    name='StockMonitor',
    version='1.0.0',
    description='股票价格偏离监控工具',
    author='',
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
