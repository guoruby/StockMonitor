import Cocoa

// MARK: - 便签窗口
//
// 设计：失焦渲染（最简单可靠的方案）
// - editView：纯文本编辑
// - previewView：富文本预览
// - 默认以预览态展示，点击进入编辑态；失焦回到预览态

class MemoPanel: NSPanel {
    private let memoId: String
    private(set) var editView: MemoTextView!
    private var previewView: MemoTextView!
    private var editScroll: NSScrollView!
    private var previewScroll: NSScrollView!
    private var isClosing = false
    private var isInEditMode = false

    init(memo: MemoItem) {
        self.memoId = memo.id

        super.init(
            contentRect: NSRect(x: memo.x, y: memo.y, width: memo.width, height: memo.height),
            styleMask: [.borderless, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hasShadow = true

        setupContent(text: memo.text)
        buildContextMenu()

        // 监听窗口焦点变化
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification, object: self
        )

        // 初始即为预览态：editScroll 隐藏，previewScroll 显示
        refreshPreview()
        editScroll.isHidden = true
        previewScroll.isHidden = false
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // MARK: - 构建 UI

    private func setupContent(text: String) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        container.panel = self

        // === 编辑 ScrollView + TextView ===
        let editScroll = MemoScrollView(frame: NSRect(x: 6, y: 4, width: 188, height: 142))
        editScroll.hasVerticalScroller = true
        editScroll.hasHorizontalScroller = false
        editScroll.borderType = .noBorder
        editScroll.drawsBackground = false
        editScroll.autohidesScrollers = true
        editScroll.autoresizingMask = [.width, .height]

        let contentSize = editScroll.contentSize
        editView = MemoTextView(frame: NSRect(origin: .zero, size: contentSize))
        editView.font = NSFont.systemFont(ofSize: 13)
        editView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        editView.backgroundColor = .clear
        editView.drawsBackground = false
        editView.isEditable = true
        editView.isSelectable = true
        editView.isRichText = false
        editView.isFieldEditor = false
        editView.allowsUndo = true
        editView.insertionPointColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        editView.delegate = self
        editView.panel = self
        editScroll.panel = self
        editView.isHorizontallyResizable = false
        editView.isVerticallyResizable = true
        editView.autoresizingMask = [.width]
        editView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editView.textContainer?.widthTracksTextView = true
        editView.string = text
        editScroll.documentView = editView
        container.addSubview(editScroll)

        // === 预览 ScrollView + TextView ===
        let previewScroll = MemoScrollView(frame: NSRect(x: 6, y: 4, width: 188, height: 142))
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = false
        previewScroll.borderType = .noBorder
        previewScroll.drawsBackground = false
        previewScroll.autohidesScrollers = true
        previewScroll.autoresizingMask = [.width, .height]

        let pSize = previewScroll.contentSize
        previewView = MemoTextView(frame: NSRect(origin: .zero, size: pSize))
        previewView.font = NSFont.systemFont(ofSize: 13)
        previewView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        previewView.backgroundColor = .clear
        previewView.drawsBackground = false
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.isRichText = true
        previewView.isFieldEditor = false
        previewView.panel = self
        previewScroll.panel = self
        previewView.isHorizontallyResizable = false
        previewView.isVerticallyResizable = true
        previewView.autoresizingMask = [.width]
        previewView.textContainer?.containerSize = NSSize(width: pSize.width, height: CGFloat.greatestFiniteMagnitude)
        previewView.textContainer?.widthTracksTextView = true
        previewScroll.documentView = previewView
        container.addSubview(previewScroll)

        self.editScroll = editScroll
        self.previewScroll = previewScroll

        contentView = container

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.layoutSubviews() }
    }

    /// 构建右键菜单并挂载到所有可交互视图上
    private func buildContextMenu() {
        let menu = NSMenu()
        let hideItem = NSMenuItem(title: "隐藏便签", action: #selector(hideMemo), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "--- 格式化语法 ---", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "**加粗文字**", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "*斜体文字*", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[red]红色[/red]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[green]绿色[/green]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[blue]蓝色[/blue]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "# 标题", action: nil, keyEquivalent: ""))

        editScroll.menu = menu
        editView.menu = menu
        previewScroll.menu = menu
        previewView.menu = menu
    }

    // MARK: - 保存

    func savePosition() {
        guard !isClosing else { return }
        let f = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(id: memoId, x: f.origin.x, y: f.origin.y,
                                 width: f.width, height: f.height)
    }

    func saveText() {
        let text = (editView.string as String)
        MemoStore.shared.update(id: memoId, text: text)
    }

    private func layoutSubviews() {
        // scrollView autoresizingMask 自动跟随 contentView
    }

    // MARK: - Cmd+拖拽

    func beginWindowDrag(with event: NSEvent) {
        performDrag(with: event)
        savePosition()
    }

    // MARK: - 右键菜单

    override func rightMouseDown(with event: NSEvent) {
        showContextMenu(at: NSEvent.mouseLocation)
    }

    func showContextMenu(at point: NSPoint) {
        let menu = NSMenu()
        let hideItem = NSMenuItem(title: "隐藏便签", action: #selector(hideMemo), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "--- 格式化语法 ---", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "**加粗文字**", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "*斜体文字*", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[red]红色[/red]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[green]绿色[/green]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[blue]蓝色[/blue]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "# 标题", action: nil, keyEquivalent: ""))
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    @objc func hideMemo() {
        let f = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(id: memoId, x: f.origin.x, y: f.origin.y,
                                 width: f.width, height: f.height)
        saveText()
        isClosing = true
        close()
        NotificationCenter.default.post(name: .memoDidHide, object: nil, userInfo: ["id": memoId])
    }

    // MARK: - 编辑/预览切换

    @objc private func windowDidResignKey(_ notification: Notification) {
        switchToPreview()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        switchToEdit()
    }

    private func switchToPreview() {
        guard isInEditMode else { return }
        saveText()
        isInEditMode = false
        refreshPreview()
        previewScroll.isHidden = false
        editScroll.isHidden = true
    }

    private func switchToEdit() {
        guard !isInEditMode else { return }
        isInEditMode = true
        editScroll.isHidden = false
        previewScroll.isHidden = true
        editView.window?.makeFirstResponder(editView)
    }

    private func refreshPreview() {
        let raw = (editView.string as String)
        previewView.textStorage?.setAttributedString(renderMarkdown(raw))
    }

    // MARK: - Markdown 渲染

    private func renderMarkdown(_ text: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            result.append(renderLine(line, baseFont: baseFont, defaultColor: defaultColor))
            if i < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [
                    .font: baseFont, .foregroundColor: defaultColor
                ]))
            }
        }
        return result
    }

    private func renderLine(_ line: String, baseFont: NSFont, defaultColor: NSColor) -> NSAttributedString {
        var font = baseFont
        var contentStart = 0
        if line.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 16)
            contentStart = 2
        } else if line.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 14)
            contentStart = 3
        }
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: defaultColor
        ]
        let nsLine = line as NSString
        let totalLen = nsLine.length
        guard contentStart < totalLen else {
            return NSAttributedString(string: "", attributes: defaultAttrs)
        }

        let pattern = "\\*\\*([^*]+)\\*\\*|\\*([^*]+)\\*|\\[red\\]([^\\[]+)\\[/red\\]|\\[green\\]([^\\[]+)\\[/green\\]|\\[blue\\]([^\\[]+)\\[/blue\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(
                string: nsLine.substring(from: contentStart),
                attributes: defaultAttrs
            )
        }

        let result = NSMutableAttributedString()
        let searchRange = NSRange(location: contentStart, length: totalLen - contentStart)
        let matches = regex.matches(in: line, range: searchRange)
        var cursor = contentStart
        for match in matches {
            if match.range.location > cursor {
                let pre = nsLine.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                result.append(NSAttributedString(string: pre, attributes: defaultAttrs))
            }
            let matched = nsLine.substring(with: match.range)
            if matched.hasPrefix("**") {
                let inner = String(matched.dropFirst(2).dropLast(2))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("*") {
                let inner = String(matched.dropFirst().dropLast())
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) ?? font
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: italicFont, .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("[red]") {
                let inner = String(matched.dropFirst(5).dropLast(6))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font, .foregroundColor: NSColor.red
                ]))
            } else if matched.hasPrefix("[green]") {
                let inner = String(matched.dropFirst(7).dropLast(8))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
                ]))
            } else if matched.hasPrefix("[blue]") {
                let inner = String(matched.dropFirst(6).dropLast(7))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font, .foregroundColor: NSColor.blue
                ]))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < totalLen {
            result.append(NSAttributedString(
                string: nsLine.substring(from: cursor),
                attributes: defaultAttrs
            ))
        }
        return result
    }
}

// MARK: - NSTextViewDelegate

extension MemoPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        saveText()
    }
}

// MARK: - Container View

class MemoContainerView: NSView {
    weak var panel: MemoPanel?

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            panel?.beginWindowDrag(with: event)
            return
        }

        // 非Cmd点击 → 进入编辑态
        panel?.makeKeyAndOrderFront(nil)
        panel?.editView.window?.makeFirstResponder(panel?.editView)
        super.mouseDown(with: event)
    }
}

class MemoScrollView: NSScrollView {
    weak var panel: MemoPanel?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            panel?.beginWindowDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - TextView

class MemoTextView: NSTextView {
    weak var panel: MemoPanel?

    /// 禁用系统默认的"编辑菜单"（复制/粘贴等），让 NSView.menu 生效
    override func menu(for event: NSEvent) -> NSMenu? {
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            panel?.beginWindowDrag(with: event)
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "a" {
            return super.performKeyEquivalent(with: event)
        }
        return false
    }
}

// MARK: - Notification

extension Notification.Name {
    static let memoDidClose = Notification.Name("memoDidClose")
    static let memoDidHide = Notification.Name("memoDidHide")
}
