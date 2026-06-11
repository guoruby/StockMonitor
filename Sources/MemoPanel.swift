import Cocoa

class MemoPanel: NSPanel {
    private let memoId: String
    var textView: MemoTextView!
    private var isClosing = false
    private var isCmdDragging = false
    private var cmdDragStartPos: NSPoint = .zero
    private var cmdDragStartFrameOrigin: NSPoint = .zero

    /// 原始纯文本（始终包含 Markdown 标记），作为数据源
    private var rawText: String = ""

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
        rawText = memo.text
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
        MemoStore.shared.update(id: memoId, text: rawText)
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

    // MARK: - 逐行渲染：当前行编辑（显示标记），其他行预览（隐藏标记，显示效果）

    /// 获取光标在 rawText 中的位置对应的行号
    private func currentLineIndex() -> Int {
        let cursorPos = textView.selectedRange.location
        // 将光标位置映射回 rawText 中的位置
        // 简化处理：因为当前行的内容=rawText对应行，直接在rawText中计算
        let lines = rawText.components(separatedBy: "\n")
        var charOffset = 0
        for (idx, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            if cursorPos <= charOffset + lineLen {
                return idx
            }
            charOffset += lineLen + 1
        }
        return max(0, lines.count - 1)
    }

    func renderPerLine() {
        guard let storage = textView.textStorage else { return }

        let currentLine = currentLineIndex()
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        // 基于 rawText 逐行构建新的 attributedString
        let result = NSMutableAttributedString()
        let lines = rawText.components(separatedBy: "\n")

        for (idx, line) in lines.enumerated() {
            if idx > 0 { result.append(NSAttributedString(string: "\n")) }

            if idx == currentLine {
                // 当前行：纯文本，保留 Markdown 标记供编辑
                result.append(NSAttributedString(string: line, attributes: [
                    .font: baseFont,
                    .foregroundColor: defaultColor
                ]))
            } else {
                // 其他行：渲染 Markdown（去掉标记符号，应用样式）
                result.append(renderMarkdownLine(line, baseFont: baseFont, defaultColor: defaultColor))
            }
        }

        // 保存当前光标位置（相对于当前行，内容一致所以偏移有效）
        let selectedRanges = textView.selectedRanges

        storage.beginEditing()
        storage.setAttributedString(result)
        storage.endEditing()

        // 恢复选中范围
        textView.selectedRanges = selectedRanges
    }

    /// 渲染单行 Markdown：去掉标记符号，应用样式
    private func renderMarkdownLine(_ line: String, baseFont: NSFont, defaultColor: NSColor) -> NSAttributedString {
        var remaining = line
        var font = baseFont

        // 标题检测
        if remaining.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 16)
            remaining = String(remaining.dropFirst(2))
        } else if remaining.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 14)
            remaining = String(remaining.dropFirst(3))
        }

        let nsRemaining = remaining as NSString

        // 匹配内联标记
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\][^\\[]+\\[/blue\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: remaining, attributes: [.font: font, .foregroundColor: defaultColor])
        }

        let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
        let result = NSMutableAttributedString()
        var lastEnd = 0

        for match in matches {
            // 前面的普通文本
            if match.range.location > lastEnd {
                let plain = nsRemaining.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: defaultColor]))
            }

            let matched = nsRemaining.substring(with: match.range)

            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                // 加粗：去掉 ** 符号，只保留内部文字 + 加粗字体
                let inner = String(matched.dropFirst(2).dropLast(2))
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") && matched.count > 2 {
                // 斜体：去掉 * 符号
                let inner = String(matched.dropFirst().dropLast())
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) ?? font
                result.append(NSAttributedString(string: inner, attributes: [
                    .font: italicFont,
                    .foregroundColor: defaultColor
                ]))
            } else if matched.hasPrefix("[red]") {
                // 红色：去掉 [red][/red] 标签
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

        // 尾部剩余
        if lastEnd < nsRemaining.length {
            let tail = nsRemaining.substring(from: lastEnd)
            result.append(NSAttributedString(string: tail, attributes: [.font: font, .foregroundColor: defaultColor]))
        }

        return result
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
        // 将当前行（用户正在编辑的）同步回 rawText
        syncCurrentLineToRawText()
        saveText()
        renderPerLine()
    }

    // 光标移动 → 切换当前行，重新渲染
    func textViewDidChangeSelection(_ notification: Notification) {
        // 先同步旧当前行的修改到 rawText，再切换渲染
        renderPerLine()
    }

    /// 把 textView 中当前行的内容写回 rawText 对应位置
    private func syncCurrentLineToRawText() {
        guard let storage = textView.textStorage else { return }
        let cursorPos = textView.selectedRange.location

        let lines = rawText.components(separatedBy: "\n")
        var charOffset = 0
        var targetLineIdx = 0
        for (idx, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            if cursorPos <= charOffset + lineLen {
                targetLineIdx = idx
                break
            }
            charOffset += lineLen + 1
        }

        // 从 storage 中提取当前行的实际文本
        let storageString = storage.string as NSString
        var storageCharOffset = 0
        var currentLineInStorage = ""
        for (idx, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            if idx == targetLineIdx {
                let end = min(storageCharOffset + lineLen, storageString.length)
                currentLineInStorage = storageString.substring(with: NSRange(location: storageCharOffset, length: end - storageCharOffset))
                break
            }
            storageCharOffset += lineLen + 1
        }

        // 更新 rawText 中的对应行
        var rawLines = rawText.components(separatedBy: "\n")
        if targetLineIdx < rawLines.count {
            rawLines[targetLineIdx] = currentLineInStorage
            rawText = rawLines.joined(separator: "\n")
        }
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
