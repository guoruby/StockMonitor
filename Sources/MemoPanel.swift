import Cocoa

// MARK: - 便签窗口
//
// 设计：
// - 始终显示 rawText（包含 Markdown 标记），保证编辑体验自然
// - 失焦时（didResignKey）整体渲染为格式化文本（去掉标记、显示样式）
// - 聚焦时（didBecomeKey）恢复为 rawText
// - 渲染过程不修改 rawText 本身，只改 textStorage 属性，且用「只重置属性不重置字符」的方式

class MemoPanel: NSPanel {
    private let memoId: String
    private(set) var textView: MemoTextView!
    private var isClosing = false
    private var isCmdDragging = false
    private var cmdDragStartPos: NSPoint = .zero
    private var cmdDragStartFrameOrigin: NSPoint = .zero

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

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.layoutSubviews() }

        // 失焦 → 渲染
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.renderMarkdown() }

        // 聚焦 → 恢复纯文本
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.clearStyles() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(text: String) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        container.panel = self

        let tvFrame = NSRect(x: 6, y: 4, width: 188, height: 142)
        textView = MemoTextView(frame: tvFrame)
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        // 关键：用 isRichText=false，让 NSTextView 自己管字体/颜色，渲染时只需 addAttribute
        textView.isRichText = false
        textView.isFieldEditor = false
        textView.allowsUndo = true
        textView.insertionPointColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        textView.delegate = self
        textView.panel = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.containerSize = NSSize(width: tvFrame.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        container.addSubview(textView)

        contentView = container

        // 直接设置 string 即可，不要 setAttributedString 引发 delegate 回调
        textView.string = text
    }

    func savePosition() {
        guard !isClosing else { return }
        let f = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(id: memoId, x: f.origin.x, y: f.origin.y,
                                 width: f.width, height: f.height)
    }

    func saveText() {
        MemoStore.shared.update(id: memoId, text: textView.string)
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
        guard let cv = contentView else { return }
        let w = cv.bounds.width
        let h = cv.bounds.height
        textView.frame = NSRect(x: 6, y: 4, width: w - 12, height: h - 8)
        textView.textContainer?.containerSize = NSSize(width: w - 18, height: CGFloat.greatestFiniteMagnitude)
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
        MemoStore.shared.update(id: memoId, text: textView.string)
        isClosing = true
        close()
        NotificationCenter.default.post(name: .memoDidHide, object: nil, userInfo: ["id": memoId])
    }

    // MARK: - Markdown 渲染

    /// 应用 Markdown 样式：标记符号本身保持显示，但被设置为与样式相同的颜色（视觉上隐去）
    /// - 关键：绝不改变 string 长度，只改 attribute
    /// - 不使用 setAttributedString（会触发回调）
    /// - 使用 NSTextStorage 的 addAttribute 配合 setAttributes
    private func renderMarkdown() {
        guard let storage = textView.textStorage else { return }
        let plain = storage.string as NSString
        let fullRange = NSRange(location: 0, length: plain.length)
        if fullRange.length == 0 { return }

        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        // 先重置全部为默认样式
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: defaultColor], range: fullRange)

        // 标题：把 # 符号本身设为与文字同色（视觉上像被替换）
        let lines = plain.components(separatedBy: "\n")
        var charOffset = 0
        for line in lines {
            let lineLen = (line as NSString).length
            if line.hasPrefix("# ") {
                storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: defaultColor],
                                      range: NSRange(location: charOffset, length: min(2, lineLen)))
            } else if line.hasPrefix("## ") {
                storage.addAttributes([.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: defaultColor],
                                      range: NSRange(location: charOffset, length: min(3, lineLen)))
            }
            charOffset += lineLen + 1
        }

        // 内联标记：加粗/斜体/颜色
        // 关键：用 addAttribute 整段染色（包括 ** * [red] 等符号），让符号与文字同色
        // 视觉效果：用户看到的只是粗体/红色文字，看不到 ** * 符号
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\][^\\[]+\\[/blue\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            storage.endEditing()
            return
        }
        let matches = regex.matches(in: plain as String, range: fullRange)
        for match in matches {
            let matched = plain.substring(with: match.range)
            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: baseFont.pointSize), range: match.range)
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") && matched.count > 2 {
                let italicDesc = baseFont.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: baseFont.pointSize) ?? baseFont
                storage.addAttribute(.font, value: italicFont, range: match.range)
            } else if matched.hasPrefix("[red]") {
                storage.addAttribute(.foregroundColor, value: NSColor.red, range: match.range)
            } else if matched.hasPrefix("[green]") {
                storage.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1), range: match.range)
            } else if matched.hasPrefix("[blue]") {
                storage.addAttribute(.foregroundColor, value: NSColor.blue, range: match.range)
            }
        }

        storage.endEditing()
    }

    /// 清除样式（恢复为默认字体/颜色），不改变 string
    private func clearStyles() {
        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        if fullRange.length == 0 { return }
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: defaultColor], range: fullRange)
        storage.endEditing()
    }
}

// MARK: - Delegate

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
            panel?.textView.window?.makeFirstResponder(panel?.textView)
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

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            isCmdDragging = true
            panel?.beginCmdDrag(NSEvent.mouseLocation)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCmdDragging { panel?.continueCmdDrag(NSEvent.mouseLocation) }
        else { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
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
