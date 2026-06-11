import Cocoa

// MARK: - 便签窗口
//
// 设计：失焦渲染（最简单可靠的方案）
// - editView：纯文本，isRichText = false，isEditable = true
// - previewView：富文本，isRichText = true，isEditable = false，显示渲染结果
// - 当前状态：
//   - 窗口是 keyWindow → 显示 editView（编辑）
//   - 窗口失去焦点 → 显示 previewView（预览，已渲染）
//   - 窗口重新获得焦点 → 切回 editView
// - 由于两个视图完全分离，不会出现 setAttributedString 递归崩溃
// - 注意：编辑过程中 editView 是纯文本（** 标记可见），预览是富文本（** 隐藏）

class MemoPanel: NSPanel {
    private let memoId: String
    private(set) var editView: MemoTextView!
    private var previewView: MemoTextView!
    private var editScroll: NSScrollView!
    private var previewScroll: NSScrollView!
    private var isClosing = false
    private var isCmdDragging = false
    private var cmdDragStartPos: NSPoint = .zero
    private var cmdDragStartFrameOrigin: NSPoint = .zero
    private var isInEditMode = true  // 是否处于编辑态

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

        // 监听窗口焦点变化
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: self
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification, object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(text: String) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        container.panel = self

        // 嵌入 scrollView 让 resize 时正确处理
        let editScroll = NSScrollView(frame: NSRect(x: 6, y: 4, width: 188, height: 142))
        editScroll.hasVerticalScroller = true
        editScroll.hasHorizontalScroller = false
        editScroll.borderType = .noBorder
        editScroll.drawsBackground = false
        editScroll.autohidesScrollers = true
        editScroll.autoresizingMask = [.width, .height]

        // 编辑视图：纯文本
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
        editView.isHorizontallyResizable = false
        editView.isVerticallyResizable = true
        editView.autoresizingMask = [.width]
        editView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editView.textContainer?.widthTracksTextView = true
        editView.string = text
        editScroll.documentView = editView
        container.addSubview(editScroll)

        // 预览视图：富文本，不可编辑
        let previewScroll = NSScrollView(frame: NSRect(x: 6, y: 4, width: 188, height: 142))
        previewScroll.hasVerticalScroller = true
        previewScroll.hasHorizontalScroller = false
        previewScroll.borderType = .noBorder
        previewScroll.drawsBackground = false
        previewScroll.autohidesScrollers = true
        previewScroll.autoresizingMask = [.width, .height]

        let pSize = previewScroll.contentSize
        previewView = MemoTextView(frame: NSRect(origin: .zero, size: pSize))
        previewView.isEditable = false
        previewView.isPreviewMode = true
        previewView.font = NSFont.systemFont(ofSize: 13)
        previewView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        previewView.backgroundColor = .clear
        previewView.drawsBackground = false
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.isRichText = true
        previewView.isFieldEditor = false
        previewView.isHorizontallyResizable = false
        previewView.isVerticallyResizable = true
        previewView.autoresizingMask = [.width]
        previewView.textContainer?.containerSize = NSSize(width: pSize.width, height: CGFloat.greatestFiniteMagnitude)
        previewView.textContainer?.widthTracksTextView = true
        previewScroll.documentView = previewView
        previewScroll.isHidden = true
        container.addSubview(previewScroll)

        // 保存 scrollView 引用，方便 resize 时调整 textView 的 frame
        self.editScroll = editScroll
        self.previewScroll = previewScroll

        contentView = container

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.layoutSubviews() }
    }

    // MARK: - 保存

    func savePosition() {
        guard !isClosing else { return }
        let f = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(id: memoId, x: f.origin.x, y: f.origin.y,
                                 width: f.width, height: f.height)
    }

    /// 保存当前内容（保留 Markdown 标记，从 editView 取）
    func saveText() {
        let text = (editView.string as String)
        MemoStore.shared.update(id: memoId, text: text)
    }

    func beginCmdDrag(_ pos: NSPoint) {
        isCmdDragging = true
        cmdDragStartPos = pos
        cmdDragStartFrameOrigin = frame.origin
    }

    func continueCmdDrag(_ pos: NSPoint) {
        guard isCmdDragging else { return }
        setFrameOrigin(NSPoint(
            x: cmdDragStartFrameOrigin.x + (pos.x - cmdDragStartPos.x),
            y: cmdDragStartFrameOrigin.y + (pos.y - cmdDragStartPos.y)
        ))
    }

    func endCmdDrag() {
        if isCmdDragging { isCmdDragging = false; savePosition() }
    }

    private func layoutSubviews() {
        // scrollView 设置了 autoresizingMask=[.width,.height]，会自动跟随 contentView 调整大小
        // textView 跟着 scrollView.contentSize 走，且 autoresizingMask=[.width] 跟随宽度
        // 容器 resize 后，contentView 也会 resize，然后 scrollView 自动填满
        // 这里不需要手动操作
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            isCmdDragging = true
            cmdDragStartPos = NSEvent.mouseLocation
            cmdDragStartFrameOrigin = frame.origin
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCmdDragging { continueCmdDrag(NSEvent.mouseLocation) }
        else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if isCmdDragging { isCmdDragging = false; savePosition() }
        else { super.mouseUp(with: event) }
    }

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

    // MARK: - 失焦渲染

    @objc private func windowDidResignKey(_ notification: Notification) {
        // 失去焦点：保存 + 切换到预览视图
        saveText()
        isInEditMode = false
        refreshPreview()
        previewScroll.isHidden = false
        editScroll.isHidden = true
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        // 获得焦点：切回编辑视图
        isInEditMode = true
        editScroll.isHidden = false
        previewScroll.isHidden = true
        editView.window?.makeFirstResponder(editView)
    }

    /// 从 editView 取最新文本，渲染成富文本，填充到 previewView
    private func refreshPreview() {
        let raw = (editView.string as String)
        previewView.textStorage?.setAttributedString(renderMarkdown(raw))
    }

    /// 把整段 Markdown 文本渲染为 AttributedString
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

    /// 解析单行 Markdown
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
    private var isCmdDragging = false

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
            isCmdDragging = true
            panel?.beginCmdDrag(NSEvent.mouseLocation)
        } else {
            panel?.makeKeyAndOrderFront(nil)
            panel?.editView.window?.makeFirstResponder(panel?.editView)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCmdDragging { panel?.continueCmdDrag(NSEvent.mouseLocation) }
    }

    override func mouseUp(with event: NSEvent) {
        if isCmdDragging { isCmdDragging = false; panel?.endCmdDrag() }
    }
}

// MARK: - TextView

class MemoTextView: NSTextView {
    weak var panel: MemoPanel?
    private var isCmdDragging = false

    /// 预览态时忽略鼠标拖拽
    var isPreviewMode: Bool = false

    override func mouseDown(with event: NSEvent) {
        if isPreviewMode { return }
        if event.modifierFlags.contains(.command) {
            isCmdDragging = true
            panel?.beginCmdDrag(NSEvent.mouseLocation)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isPreviewMode { return }
        if isCmdDragging { panel?.continueCmdDrag(NSEvent.mouseLocation) }
        else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if isPreviewMode { return }
        if isCmdDragging { isCmdDragging = false; panel?.endCmdDrag() }
        else { super.mouseUp(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        panel?.showContextMenu(at: NSEvent.mouseLocation)
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
