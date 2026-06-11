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
        let openMemoItem = statusMenu.addItem(withTitle: "打开便签", action: nil, keyEquivalent: "o")
        openMemoItem.submenu = buildOpenMemoSubmenu()
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

    // 构建便签子菜单（动态内容）
    private func buildOpenMemoSubmenu() -> NSMenu {
        let menu = NSMenu(title: "打开便签")
        menu.delegate = self
        return menu
    }

    // 便签预览标题：第一行非空内容，超长截断
    private func memoPreviewTitle(_ memo: MemoItem) -> String {
        let firstLine = memo.text
            .components(separatedBy: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "(空便签)"
        let cleaned = firstLine
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "[red]", with: "")
            .replacingOccurrences(of: "[/red]", with: "")
            .replacingOccurrences(of: "[green]", with: "")
            .replacingOccurrences(of: "[/green]", with: "")
            .replacingOccurrences(of: "[blue]", with: "")
            .replacingOccurrences(of: "[/blue]", with: "")
            .replacingOccurrences(of: "# ", with: "")
            .replacingOccurrences(of: "## ", with: "")
            .trimmingCharacters(in: .whitespaces)
        let prefix = memoPanels[memo.id] != nil ? "● " : "○ "
        let display = cleaned.isEmpty ? "(空便签)" : cleaned
        return prefix + (display.count > 30 ? String(display.prefix(30)) + "…" : display)
    }

    @objc private func openSpecificMemo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let memo = MemoStore.shared.memos.first(where: { $0.id == id }) else { return }
        if let panel = memoPanels[id] {
            panel.orderFrontRegardless()
        } else {
            showMemoPanel(memo)
        }
    }

    @objc private func deleteMemo(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "删除便签？"
        alert.informativeText = "此操作不可撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            memoPanels[id]?.close()
            memoPanels.removeValue(forKey: id)
            MemoStore.shared.remove(id: id)
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
        } else if menu.title == "打开便签" {
            // 动态刷新便签列表
            menu.removeAllItems()
            let memos = MemoStore.shared.memos
            if memos.isEmpty {
                menu.addItem(withTitle: "(暂无便签)", action: nil, keyEquivalent: "")
                return
            }
            for memo in memos {
                let title = memoPreviewTitle(memo)
                let item = NSMenuItem(title: title, action: #selector(openSpecificMemo(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = memo.id
                if memoPanels[memo.id] != nil {
                    item.state = .on
                }
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            // 每个便签带一个删除子项
            for memo in memos {
                let delItem = NSMenuItem(title: "删除：\(memoPreviewTitle(memo))", action: #selector(deleteMemo(_:)), keyEquivalent: "")
                delItem.target = self
                delItem.representedObject = memo.id
                menu.addItem(delItem)
            }
        }
    }
}
