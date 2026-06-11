import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var floatingPanel: FloatingPanel?
    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var settingsWindow: NSWindow?
    var memoPanels: [String: MemoPanel] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.info("应用启动，日志目录: \(Logger.shared.logDirPath)")
        Logger.shared.info("日志文件: \(Logger.shared.logFilePath)")

        setupMenuBarIcon()
        setupFloatingPanel()
        restoreMemos()
        _ = HotkeyManager.shared

        NotificationCenter.default.addObserver(
            forName: .memoDidClose, object: nil, queue: .main
        ) { [weak self] notification in
            if let id = notification.userInfo?["id"] as? String {
                self?.memoPanels.removeValue(forKey: id)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .memoDidHide, object: nil, queue: .main
        ) { [weak self] notification in
            if let id = notification.userInfo?["id"] as? String {
                self?.memoPanels.removeValue(forKey: id)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .toggleMonitoring, object: nil, queue: .main
        ) { [weak self] _ in
            self?.floatingPanel?.toggleMonitoring()
        }

        NotificationCenter.default.addObserver(
            forName: .shakeWindow, object: nil, queue: .main
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let dx = userInfo["dx"] as? CGFloat,
                  let dy = userInfo["dy"] as? CGFloat else { return }
            self?.floatingPanel?.shakeWindow(dx: dx, dy: dy)
        }

        NotificationCenter.default.addObserver(
            forName: .monitoringStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateMenuBarIcon()
        }

        NotificationCenter.default.addObserver(
            forName: .openSettings, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openSettings()
        }

        Logger.shared.info("应用初始化完成")
    }

    private func setupMenuBarIcon() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "股票监控")
        statusItem.button?.image?.size = NSSize(width: 18, height: 18)

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusMenu.addItem(withTitle: "显示/隐藏窗口", action: #selector(togglePanel), keyEquivalent: "h")
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(withTitle: "开始/停止监控", action: #selector(toggleMonitoring), keyEquivalent: "l")
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(withTitle: "新建便签", action: #selector(newMemo), keyEquivalent: "n")
        statusMenu.addItem(withTitle: "显示所有便签", action: #selector(showAllMemos), keyEquivalent: "")
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(withTitle: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        statusMenu.addItem(withTitle: "打开日志文件夹", action: #selector(openLogFolder), keyEquivalent: "")
        statusMenu.addItem(NSMenuItem.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "q")
        statusItem.menu = statusMenu
    }

    private func setupFloatingPanel() {
        floatingPanel = FloatingPanel()
        floatingPanel?.show()
        floatingPanel?.orderFrontRegardless()
        floatingPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateMenuBarIcon() {
        let isMonitoring = MonitorState.shared.isMonitoring
        if isMonitoring {
            statusItem.button?.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "监控中")
        } else {
            statusItem.button?.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "股票监控")
        }
        statusItem.button?.image?.size = NSSize(width: 18, height: 18)
    }

    @objc private func togglePanel() {
        if let panel = floatingPanel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            floatingPanel?.show()
            floatingPanel?.orderFrontRegardless()
            floatingPanel?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func toggleMonitoring() {
        floatingPanel?.toggleMonitoring()
    }

    @objc private func newMemo() {
        let screenFrame = NSScreen.main!.visibleFrame
        let offsetX = Double(memoPanels.count % 5) * 30
        let offsetY = Double(memoPanels.count % 5) * 30
        let x = screenFrame.minX + 100 + offsetX
        let y = screenFrame.maxY - 250 - offsetY

        let memo = MemoItem(
            id: UUID().uuidString,
            text: "",
            x: x, y: y,
            width: 200, height: 150,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        MemoStore.shared.add(memo)
        showMemoPanel(memo)
    }

    private func restoreMemos() {
        for memo in MemoStore.shared.memos {
            showMemoPanel(memo)
        }
    }

    @objc private func showAllMemos() {
        for memo in MemoStore.shared.memos {
            if memoPanels[memo.id] == nil {
                showMemoPanel(memo)
            } else {
                // 已经打开则提到最前
                memoPanels[memo.id]?.orderFrontRegardless()
            }
        }
    }

    private func showMemoPanel(_ memo: MemoItem) {
        let panel = MemoPanel(memo: memo)
        panel.orderFrontRegardless()
        memoPanels[memo.id] = panel
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView().environmentObject(MonitorState.shared)
        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 450, height: 440)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
        Logger.shared.info("设置窗口已打开")
    }

    @objc private func openLogFolder() {
        let path = Logger.shared.logDirPath
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        Logger.shared.info("打开日志文件夹: \(path)")
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        floatingPanel?.show()
        floatingPanel?.orderFrontRegardless()
        floatingPanel?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu == statusMenu {
            let monitorItem = menu.items[safe: 2]
            monitorItem?.title = MonitorState.shared.isMonitoring ? "停止监控" : "开始监控"
        }
    }
}
