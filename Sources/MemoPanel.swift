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

        // 失焦 → 渲染Markdown
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.reapplyMarkdownStyle() }

        // 聚焦 → 恢复纯文本显示
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.clearStyles() }
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

        // 初始加载（纯文本，避免首次渲染闪动）
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
        // 保存时只存纯文本（去掉格式符号，保留 Markdown 标记）
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

    // 重新应用 Markdown 样式（保留光标位置）
    func reapplyMarkdownStyle() {
        guard let storage = textView.textStorage else { return }
        let plain = storage.string as NSString
        let fullRange = NSRange(location: 0, length: plain.length)
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        // 重置全部为默认样式
        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: defaultColor], range: fullRange)

        // 逐行处理（标题）
        let lines = plain.components(separatedBy: "\n")
        var lineStart = 0
        for line in lines {
            let lineLen = (line as NSString).length
            if line.hasPrefix("# ") {
                storage.addAttributes([
                    .font: NSFont.boldSystemFont(ofSize: 16),
                    .foregroundColor: defaultColor
                ], range: NSRange(location: lineStart, length: 2))
            } else if line.hasPrefix("## ") {
                storage.addAttributes([
                    .font: NSFont.boldSystemFont(ofSize: 14),
                    .foregroundColor: defaultColor
                ], range: NSRange(location: lineStart, length: 3))
            }
            lineStart += lineLen + 1 // +1 for newline
        }

        // 处理内联标记
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\][^\\[]+\\[/blue\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            storage.endEditing()
            return
        }
        let matches = regex.matches(in: plain as String, range: fullRange)

        for match in matches {
            let matched = plain.substring(with: match.range)
            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                let inner = String(matched.dropFirst(2).dropLast(2))
                applyInline(storage: storage, at: match.range, originalLength: matched.count, newString: inner) {
                    NSFont.boldSystemFont(ofSize: baseFont.pointSize)
                }
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") && matched.count > 2 {
                let inner = String(matched.dropFirst().dropLast())
                let italicDesc = baseFont.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: baseFont.pointSize) ?? baseFont
                applyInline(storage: storage, at: match.range, originalLength: matched.count, newString: inner) {
                    italicFont
                }
            } else if matched.hasPrefix("[red]") {
                let inner = String(matched.dropFirst(5).dropLast(6))
                applyInline(storage: storage, at: match.range, originalLength: matched.count, newString: inner) {
                    NSColor.red
                }
            } else if matched.hasPrefix("[green]") {
                let inner = String(matched.dropFirst(7).dropLast(8))
                applyInline(storage: storage, at: match.range, originalLength: matched.count, newString: inner) {
                    NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
                }
            } else if matched.hasPrefix("[blue]") {
                let inner = String(matched.dropFirst(6).dropLast(7))
                applyInline(storage: storage, at: match.range, originalLength: matched.count, newString: inner) {
                    NSColor.blue
                }
            }
        }

        storage.endEditing()
    }

    // 给内联标记整段染色（包括 Markdown 符号本身），视觉上符号也变色
    private func applyInline(storage: NSTextStorage, at range: NSRange, originalLength: Int, newString: String, attr: () -> Any) {
        if let font = attr() as? NSFont {
            storage.addAttribute(.font, value: font, range: range)
        }
        if let color = attr() as? NSColor {
            storage.addAttribute(.foregroundColor, value: color, range: range)
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

    // 清除所有样式（恢复纯文本显示，不改变字符串内容）
    func clearStyles() {
        guard let storage = textView.textStorage else { return }
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        storage.beginEditing()
        storage.setAttributes(
            [.font: baseFont, .foregroundColor: defaultColor],
            range: NSRange(location: 0, length: storage.length)
        )
        storage.endEditing()
    }

    func showContextMenu(at point: NSPoint) {
        let menu = NSMenu()
        let hideItem = NSMenuItem(title: "隐藏便签", action: #selector(hideMemo), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "--- 格式化语法（直接输入即可）---", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "**加粗文字**", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "*斜体文字*", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[red]红色[/red]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[green]绿色[/green]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "[blue]蓝色[/blue]", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "# 标题", action: nil, keyEquivalent: ""))
        menu.popUp(positioning: nil, at: point, in: nil)
    }

    // 隐藏便签（数据保留，可通过"显示便签"重新打开）
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
        // 不在编辑时实时渲染，避免光标错乱；只在失焦时渲染
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
        var remaining = line
        var font = baseFont

        // 标题 # / ##
        if remaining.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 16)
            remaining = String(remaining.dropFirst(2))
        } else if remaining.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 14)
            remaining = String(remaining.dropFirst(3))
        }

        let nsLine = remaining as NSString

        // 匹配：加粗、斜体、颜色
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\]\\[/red\\])|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\]\\[/green\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\]\\[/blue\\])|(\\[blue\\][^\\[]+\\[/blue\\])"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: remaining, attributes: [.font: font, .foregroundColor: defaultColor])
        }

        let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsLine.length))
        var lastEnd = 0

        for match in matches {
            if match.range.location > lastEnd {
                let plain = nsLine.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: defaultColor]))
            }

            let matched = nsLine.substring(with: match.range)

            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                let inner = String(matched.dropFirst(2).dropLast(2))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") && matched.count > 2 {
                let inner = String(matched.dropFirst().dropLast())
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) ?? font
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: italicFont,
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("[red]") {
                let inner: String
                if matched == "[red][/red]" { inner = "" }
                else { inner = String(matched.dropFirst(5).dropLast(6)) }
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.red
                ]))
            } else if matched.hasPrefix("[green]") {
                let inner: String
                if matched == "[green][/green]" { inner = "" }
                else { inner = String(matched.dropFirst(7).dropLast(8)) }
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
                ]))
            } else if matched.hasPrefix("[blue]") {
                let inner: String
                if matched == "[blue][/blue]" { inner = "" }
                else { inner = String(matched.dropFirst(6).dropLast(7)) }
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: font,
                    .foregroundColor: NSColor.blue
                ]))
            }

            lastEnd = match.range.location + match.range.length
        }

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
    static let memoDidHide = Notification.Name("memoDidHide")
}
