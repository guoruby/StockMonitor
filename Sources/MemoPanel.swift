import Cocoa

// MARK: - 便签窗口
//
// 设计：Typora 风格 - 边输边渲染
// - 单一 NSTextView，isRichText = true
// - 用户输入时立即把当前段落重新渲染（去掉标记、应用样式）
// - 渲染使用 NSMutableAttributedString 替换，不影响光标定位（在同一行内操作）
// - 为了避免崩溃，渲染只针对"当前段"（光标所在段），不影响其他段

class MemoPanel: NSPanel {
    private let memoId: String
    private(set) var editView: MemoTextView!
    private var isClosing = false
    private var isCmdDragging = false
    private var cmdDragStartPos: NSPoint = .zero
    private var cmdDragStartFrameOrigin: NSPoint = .zero
    private var isRendering = false  // 防止渲染过程触发自身

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
        // 首屏渲染：对所有行应用样式
        renderAllLinesOnOpen()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(text: String) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        container.panel = self

        let tvFrame = NSRect(x: 6, y: 4, width: 188, height: 142)
        editView = MemoTextView(frame: tvFrame)
        editView.font = NSFont.systemFont(ofSize: 13)
        editView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        editView.backgroundColor = .clear
        editView.drawsBackground = false
        editView.isEditable = true
        editView.isSelectable = true
        editView.isRichText = true  // 必须 true 才能显示加粗/颜色
        editView.isFieldEditor = false
        editView.allowsUndo = true
        editView.insertionPointColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        editView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        ]
        editView.delegate = self
        editView.panel = self
        editView.isVerticallyResizable = true
        editView.isHorizontallyResizable = false
        editView.autoresizingMask = [.width, .height]
        editView.textContainer?.containerSize = NSSize(width: tvFrame.width, height: CGFloat.greatestFiniteMagnitude)
        editView.textContainer?.widthTracksTextView = true
        editView.textStorage?.delegate = self
        // 初始显示原始文本
        editView.string = text
        container.addSubview(editView)

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

    /// 保存当前内容（保留 Markdown 标记）
    /// editView.string 没有被修改字符串长度，只改样式，所以直接取 string 即可
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
        guard let cv = contentView else { return }
        let w = cv.bounds.width
        let h = cv.bounds.height
        editView.frame = NSRect(x: 6, y: 4, width: w - 12, height: h - 8)
        editView.textContainer?.containerSize = NSSize(width: w - 18, height: CGFloat.greatestFiniteMagnitude)
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

    // MARK: - Typora 风格：换行实时渲染

    /// 触发时机：用户按回车（textStorage 出现 \n）
    /// 行为：只渲染"刚结束的那一行"（\n 之前），当前行（光标所在）保持编辑态
    /// 策略：只改样式不改字符串，** 符号保留但染灰，模拟 Typora 体验
    private func handleTextChange() {
        guard !isRendering else { return }
        guard let storage = editView.textStorage else { return }

        // 检测本次编辑是否插入了 \n
        let editedRange = storage.editedRange
        guard editedRange.location != NSNotFound, editedRange.length > 0 else { return }
        let nsString = storage.string as NSString
        let editedText = nsString.substring(with: editedRange)
        guard editedText.contains("\n") else { return }

        // 找到刚插入的 \n 的位置（在 editedRange 内）
        let localNewlinePos = (editedText as NSString).range(of: "\n").location
        let globalNewlinePos = editedRange.location + localNewlinePos

        // 该 \n 之前的那一行就是刚编辑完成、用户已离开的行
        let beforeNewline = NSRange(location: 0, length: globalNewlinePos)
        var lineRange = nsString.lineRange(for: beforeNewline)
        if lineRange.length > 0 {
            let firstCharLoc = lineRange.location
            if firstCharLoc < nsString.length,
               nsString.substring(with: NSRange(location: firstCharLoc, length: 1)) == "\n" {
                lineRange.location += 1
                lineRange.length -= 1
            }
        }
        guard lineRange.length > 0 else { return }

        let lineText = nsString.substring(with: lineRange)
        applyMarkdownAttributes(to: storage, lineText: lineText, lineRange: lineRange)
    }

    /// 不改字符串，只改属性：**xxx** → 整段加粗，** 符号字号设为 0（不可见）
    /// 这样保存时 editView.string 仍保留原始 MD 标记，下次打开可重新渲染
    private func applyMarkdownAttributes(to storage: NSTextStorage, lineText: String, lineRange: NSRange) {
        guard lineRange.length > 0 else { return }
        let baseFont = NSFont.systemFont(ofSize: 13)
        let zeroFont = NSFont.systemFont(ofSize: 0)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)

        var font = baseFont
        if lineText.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 16)
        } else if lineText.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 14)
        }

        isRendering = true
        storage.beginEditing()
        // 整行重置
        storage.setAttributes(
            [.font: font, .foregroundColor: defaultColor],
            range: lineRange
        )

        // 匹配 **xxx** / *xxx* / [red]xxx[/red]
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\][^\\[]+\\[/blue\\])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            storage.endEditing()
            isRendering = false
            return
        }
        let nsLine = lineText as NSString
        let matches = regex.matches(in: lineText, range: NSRange(location: 0, length: nsLine.length))

        for match in matches {
            let absRange = NSRange(location: lineRange.location + match.range.location, length: match.range.length)
            let matched = nsLine.substring(with: match.range)
            if matched.hasPrefix("**") && matched.hasSuffix("**") && matched.count >= 4 {
                // **xxx** → 整体加粗，两个 ** 各用2字符字号设0
                storage.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: font.pointSize), range: absRange)
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location, length: 2))
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location + absRange.length - 2, length: 2))
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") && matched.count >= 2 {
                let italicDesc = font.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: font.pointSize) ?? font
                storage.addAttribute(.font, value: italicFont, range: absRange)
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location, length: 1))
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location + absRange.length - 1, length: 1))
            } else if matched.hasPrefix("[red]") {
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location, length: 5))
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location + absRange.length - 6, length: 6))
                storage.addAttribute(.foregroundColor, value: NSColor.red, range: absRange)
            } else if matched.hasPrefix("[green]") {
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location, length: 7))
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location + absRange.length - 8, length: 8))
                storage.addAttribute(.foregroundColor, value: NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1), range: absRange)
            } else if matched.hasPrefix("[blue]") {
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location, length: 6))
                storage.addAttribute(.font, value: zeroFont, range: NSRange(location: absRange.location + absRange.length - 7, length: 7))
                storage.addAttribute(.foregroundColor, value: NSColor.blue, range: absRange)
            }
        }

        // 标题前缀隐藏
        if lineText.hasPrefix("# ") {
            storage.addAttribute(.font, value: zeroFont, range: NSRange(location: lineRange.location, length: 2))
        } else if lineText.hasPrefix("## ") {
            storage.addAttribute(.font, value: zeroFont, range: NSRange(location: lineRange.location, length: 3))
        }

        storage.endEditing()
        isRendering = false
    }

    /// 首屏渲染：对所有行应用样式（仅在初始化时调用一次）
    private func renderAllLinesOnOpen() {
        guard let storage = editView.textStorage else { return }
        let plain = storage.string as NSString
        var searchStart = 0
        let fullLength = plain.length
        while searchStart < fullLength {
            let restRange = NSRange(location: searchStart, length: fullLength - searchStart)
            let lineRange = plain.lineRange(for: restRange)
            if lineRange.length == 0 { break }
            let lineText = plain.substring(with: lineRange)
            applyMarkdownAttributes(to: storage, lineText: lineText, lineRange: lineRange)
            searchStart = lineRange.location + lineRange.length
        }
    }
}

// MARK: - NSTextViewDelegate

extension MemoPanel: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        saveText()
    }
}

// MARK: - NSTextStorageDelegate (Typora 风格实时渲染)

extension MemoPanel: NSTextStorageDelegate {
    override func textStorageDidProcessEditing(_ notification: Notification) {
        // 只在用户实际编辑时触发，不在 setAttributedString 渲染时触发
        guard !isRendering else { return }
        let storage = editView.textStorage
        guard let storage = storage else { return }
        // editedMask: .editedCharacters 表示用户输入了字符
        if storage.editedMask.contains(.editedCharacters) {
            handleTextChange()
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
