import Cocoa

class MemoPanel: NSPanel {
    private let memoId: String
    private var scrollView: NSScrollView!
    private var textView: MemoTextView!
    private var previewLabel: NSTextField!
    var isEditing = true
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

        // 关键修复：允许成为keyWindow才能输入文字
        becomesKeyOnlyIfNeeded = false

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hasShadow = true
        acceptsMouseMovedEvents = true

        setupContent(memo: memo)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.layoutSubviews() }
    }

    // MARK: 必须 override 才能让 borderless window 成为 key

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(memo: MemoItem) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: memo.width, height: memo.height))
        container.panel = self

        // 编辑区（NSScrollView + NSTextView）
        scrollView = NSScrollView(frame: NSRect(x: 6, y: 4, width: memo.width - 12, height: memo.height - 8))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView = MemoTextView()
        textView.string = memo.text
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isFieldEditor = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.insertionPointColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        textView.delegate = self
        textView.panel = self
        textView.minSize = NSSize(width: 80, height: 40)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: memo.width - 24, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        container.addSubview(scrollView)

        // 预览区（默认隐藏）
        previewLabel = NSTextField(labelWithString: "")
        previewLabel.font = NSFont.systemFont(ofSize: 13)
        previewLabel.isEditable = false
        previewLabel.isSelectable = false
        previewLabel.drawsBackground = false
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.isHidden = true
        container.addSubview(previewLabel)

        contentView = container
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
        let frame = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(id: memoId, x: frame.origin.x, y: frame.origin.y,
                                 width: frame.width, height: frame.height)
    }

    func saveText() {
        MemoStore.shared.update(id: memoId, text: textView.string)
    }

    func beginCmdDrag(_ startPos: NSPoint) {
        isCmdDragging = true
        cmdDragStartPos = startPos
        cmdDragStartFrameOrigin = frame.origin
    }

    func continueCmdDrag(_ currentPos: NSPoint) {
        guard isCmdDragging else { return }
        let dx = currentPos.x - cmdDragStartPos.x
        let dy = currentPos.y - cmdDragStartPos.y
        setFrameOrigin(NSPoint(x: cmdDragStartFrameOrigin.x + dx, y: cmdDragStartFrameOrigin.y + dy))
    }

    func endCmdDrag() {
        if isCmdDragging {
            isCmdDragging = false
            savePosition()
        }
    }

    // MARK: - 编辑/预览切换

    func switchToPreview() {
        guard isEditing else { return }
        isEditing = false
        saveText()
        let rendered = MarkdownRenderer.render(textView.string)
        previewLabel.attributedStringValue = rendered
        previewLabel.frame = scrollView.frame
        previewLabel.isHidden = false
        scrollView.isHidden = true
    }

    func switchToEdit() {
        guard !isEditing else { return }
        isEditing = true
        previewLabel.isHidden = true
        scrollView.isHidden = false
        makeKeyAndOrderFront(nil)
        textView.window?.makeFirstResponder(textView)
    }

    private func layoutSubviews() {
        guard let cv = contentView else { return }
        let w = cv.bounds.width
        let h = cv.bounds.height
        scrollView.frame = NSRect(x: 6, y: 4, width: w - 12, height: h - 8)
        if !isEditing {
            previewLabel.frame = scrollView.frame
        }
        textView.textContainer?.containerSize = NSSize(width: w - 24, height: .greatestFiniteMagnitude)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            isCmdDragging = true
            cmdDragStartPos = NSEvent.mouseLocation
            cmdDragStartFrameOrigin = frame.origin
        } else if !isEditing {
            switchToEdit()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCmdDragging {
            continueCmdDrag(NSEvent.mouseLocation)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isCmdDragging {
            isCmdDragging = false
            savePosition()
        } else {
            super.mouseUp(with: event)
        }
    }

    override func resignMain() {
        super.resignMain()
        if !isClosing && isEditing {
            switchToPreview()
        }
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
        } else if !(panel?.isEditing ?? true) {
            panel?.switchToEdit()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCmdDragging { panel?.continueCmdDrag(NSEvent.mouseLocation) }
    }

    override func mouseUp(with event: NSEvent) {
        if isCmdDragging { isCmdDragging = false; panel?.endCmdDrag() }
    }
}

// MARK: - TextView（可编辑，Cmd+拖拽移动）

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
        if isCmdDragging {
            panel?.continueCmdDrag(NSEvent.mouseLocation)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isCmdDragging {
            isCmdDragging = false
            panel?.endCmdDrag()
        } else {
            super.mouseUp(with: event)
        }
    }

    // 右键菜单：关闭 + 格式化帮助
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let closeItem = menu.addItem(withTitle: "关闭便签", action: #selector(panel?.closeMemo), keyEquivalent: "")
        closeItem.target = panel
        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "--- 格式化语法 ---", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "**加粗文字**", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "*斜体文字*", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "[red]红色文字[/red]", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "[green]绿色文字[/green]", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "[blue]蓝色文字[/blue]", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "# 标题", action: nil, keyEquivalent: "")

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" {
            return super.performKeyEquivalent(with: event)
        }
        // Cmd+Enter 切换到预览
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "\r" {
            panel?.switchToPreview()
            return true
        }
        return false
    }
}

// MARK: - Markdown 渲染器

enum MarkdownRenderer {
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        for (i, line) in lines.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(renderLine(line, baseFont: baseFont, defaultColor: defaultColor))
        }
        return result
    }

    private static func renderLine(_ line: String, baseFont: NSFont, defaultColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // 处理标题 #
        var remaining = line
        var font = baseFont
        if remaining.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 16)
            remaining = String(remaining.dropFirst(2))
        } else if remaining.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 14)
            remaining = String(remaining.dropFirst(3))
        }

        // 正则匹配所有标记
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\]\\[/red\\])|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\]\\[/green\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\]\\[/blue\\])|(\\[blue\\][^\\[]+\\[/blue\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: remaining, attributes: [.font: font, .foregroundColor: defaultColor])
        }

        let nsLine = remaining as NSString
        let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsLine.length))
        var lastEnd = 0

        for match in matches {
            // 前面的普通文本
            if match.range.location > lastEnd {
                let plain = nsLine.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: defaultColor]))
            }

            let matched = nsLine.substring(with: match.range)

            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                // 加粗
                let inner = String(matched.dropFirst(2).dropLast(2))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") {
                // 斜体
                let inner = String(matched.dropFirst().dropLast())
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) ?? font
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: italicFont,
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("[red]") {
                let inner: String
                if matched == "[red][/red]" {
                    inner = ""
                } else {
                    inner = String(matched.dropFirst(5).dropLast(6))
                }
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.red
                ]))
            } else if matched.hasPrefix("[green]") {
                let inner: String
                if matched == "[green][/green]" {
                    inner = ""
                } else {
                    inner = String(matched.dropFirst(7).dropLast(8))
                }
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
                ]))
            } else if matched.hasPrefix("[blue]") {
                let inner: String
                if matched == "[blue][/blue]" {
                    inner = ""
                } else {
                    inner = String(matched.dropFirst(6).dropLast(7))
                }
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.blue
                ]))
            }

            lastEnd = match.range.location + match.range.length
        }

        // 尾部剩余文本
        if lastEnd < nsLine.length {
            let tail = nsLine.substring(from: lastEnd)
            result.append(NSAttributedString(string: tail, attributes: [.font: font, .foregroundColor: defaultColor]))
        }

        return result
    }
}

// MARK: - Notification

extension Notification.Name {
    static let memoDidClose = Notification.Name("memoDidClose")
}
