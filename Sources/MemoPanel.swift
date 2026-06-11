import Cocoa

class MemoPanel: NSPanel {
    private let memoId: String
    var textView: MemoTextView!
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

        setupContent(memo: memo)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.layoutSubviews() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(memo: MemoItem) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: memo.width, height: memo.height))
        container.panel = self

        let tvFrame = NSRect(x: 6, y: 4, width: memo.width - 12, height: memo.height - 8)
        textView = MemoTextView(frame: tvFrame)
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
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

        // 初始加载
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: memo.text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
            ]
        ))
    }

    @objc func closeMemo() {
        isClosing = true
        savePosition()
        saveText()
        MemoStore.shared.remove(id: memoId)
        close()
        NotificationCenter.default.post(name: .memoDidClose, object: nil, userInfo: ["id": memoId])
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

    // MARK: - 逐行渲染：当前行编辑，其他行预览

    /// 获取光标所在的行号（从0开始）
    private func currentLineIndex() -> Int? {
        guard let storage = textView.textStorage else { return nil }
        let cursorPos = textView.selectedRange.location
        if cursorPos >= storage.length { return storage.string.components(separatedBy: "\n").count - 1 }
        let plain = storage.string as NSString
        var lineIdx = 0
        for line in plain.components(separatedBy: "\n") {
            if cursorPos <= lineIdx + (line as NSString).length {
                return lineIdx
            }
            lineIdx += (line as NSString).length + 1 // +1 for \n
        }
        return lineIdx
    }

    /// 核心：逐行渲染，当前行纯文本，其他行 Markdown 预览
    func renderPerLine() {
        guard let storage = textView.textStorage else { return }
        let plain = storage.string as NSString

        // 光标所在行（如果正在输入）
        let currentLine = currentLineIndex()

        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        storage.beginEditing()

        // 全部先设为默认样式
        storage.setAttributes([.font: baseFont, .foregroundColor: defaultColor],
                              range: NSRange(location: 0, length: plain.length))

        // 逐行处理
        let lines = plain.components(separatedBy: "\n")
        var charOffset = 0
        for (lineIdx, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            let lineRange = NSRange(location: charOffset, length: lineLen == 0 ? 0 : lineLen)

            if lineIdx == currentLine {
                // 当前行：纯文本，不渲染 Markdown
                charOffset += lineLen + 1
                continue
            }

            // 非当前行：渲染 Markdown
            renderMarkdownForLine(line: line, inStorage: storage, at: lineRange, baseFont: baseFont, defaultColor: defaultColor)

            charOffset += lineLen + 1
        }

        storage.endEditing()
    }

    /// 对单行应用 Markdown 渲染
    private func renderMarkdownForLine(line: String, inStorage storage: NSTextStorage, at lineRange: NSRange, baseFont: NSFont, defaultColor: NSColor) {
        var remaining = line
        var font = baseFont

        // 标题
        if remaining.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 16)
            storage.addAttributes([.font: font], range: NSRange(location: lineRange.location, length: min(2, lineRange.length)))
        } else if remaining.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 14)
            storage.addAttributes([.font: font], range: NSRange(location: lineRange.location, length: min(3, lineRange.length)))
        }

        // 内联标记
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\][^\\[]+\\[/blue\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        let nsLine = remaining as NSString
        let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            // 匹配到的 range 是相对于行的，需要加上行偏移
            let absRange = NSRange(
                location: lineRange.location + match.range.location,
                length: match.range.length
            )
            let matched = nsLine.substring(with: match.range)

            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                storage.addAttributes([
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                    .foregroundColor: defaultColor
                ], range: absRange)
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") && matched.count > 2 {
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) ?? font
                storage.addAttributes([.font: italicFont, .foregroundColor: defaultColor], range: absRange)
            } else if matched.hasPrefix("[red]") {
                storage.addAttributes([.font: font, .foregroundColor: NSColor.red], range: absRange)
            } else if matched.hasPrefix("[green]") {
                storage.addAttributes([.font: font, .foregroundColor: NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)], range: absRange)
            } else if matched.hasPrefix("[blue]") {
                storage.addAttributes([.font: font, .foregroundColor: NSColor.blue], range: absRange)
            }
        }
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
}

// MARK: - Delegate

extension MemoPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        saveText()
        renderPerLine()
    }

    // 光标移动 → 切换当前行，重新渲染
    func textViewDidChangeSelection(_ notification: Notification) {
        renderPerLine()
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
