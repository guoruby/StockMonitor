import Cocoa

// MARK: - 便签窗口
//
// 设计：双 NSTextView 叠加
// - editView: 负责编辑，始终显示 rawText（包含 Markdown 标记）
// - previewView: 负责预览，显示渲染后的内容（标记去除 + 样式应用）
// - 编辑时（keyWindow）显示 editView，隐藏 previewView
// - 失焦时隐藏 editView，显示 previewView
// 两个 view 互不干扰，彻底解决 setAttributedString 在编辑时触发的各种问题

class MemoPanel: NSPanel {
    private let memoId: String
    private(set) var editView: MemoTextView!
    private var previewView: NSTextView!
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

        // 失焦 → 切到预览
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.showPreview() }

        // 聚焦 → 切到编辑
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main
        ) { [weak self] _ in self?.showEditor() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func setupContent(text: String) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        container.panel = self

        let tvFrame = NSRect(x: 6, y: 4, width: 188, height: 142)

        // 1. 编辑层
        editView = MemoTextView(frame: tvFrame)
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
        editView.isVerticallyResizable = true
        editView.isHorizontallyResizable = false
        editView.autoresizingMask = [.width, .height]
        editView.textContainer?.containerSize = NSSize(width: tvFrame.width, height: CGFloat.greatestFiniteMagnitude)
        editView.textContainer?.widthTracksTextView = true
        editView.string = text
        container.addSubview(editView)

        // 2. 预览层（覆盖在编辑层上，失焦时显示）
        previewView = NSTextView(frame: tvFrame)
        previewView.font = NSFont.systemFont(ofSize: 13)
        previewView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        previewView.backgroundColor = .clear
        previewView.drawsBackground = false
        previewView.isEditable = false
        previewView.isSelectable = true
        previewView.isRichText = true
        previewView.isFieldEditor = false
        previewView.isVerticallyResizable = true
        previewView.isHorizontallyResizable = false
        previewView.autoresizingMask = [.width, .height]
        previewView.textContainer?.containerSize = NSSize(width: tvFrame.width, height: CGFloat.greatestFiniteMagnitude)
        previewView.textContainer?.widthTracksTextView = true
        previewView.isHidden = true
        container.addSubview(previewView)

        contentView = container
    }

    // MARK: - 编辑/预览切换

    private func showEditor() {
        editView.isHidden = false
        previewView.isHidden = true
    }

    private func showPreview() {
        // 同步 editView 内容到 previewView（渲染版）
        let rendered = MarkdownRenderer.render(editView.string)
        previewView.textStorage?.setAttributedString(rendered)
        editView.isHidden = true
        previewView.isHidden = false
    }

    // MARK: - 保存

    func savePosition() {
        guard !isClosing else { return }
        let f = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(id: memoId, x: f.origin.x, y: f.origin.y,
                                 width: f.width, height: f.height)
    }

    func saveText() {
        MemoStore.shared.update(id: memoId, text: editView.string)
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
        let f = NSRect(x: 6, y: 4, width: w - 12, height: h - 8)
        editView.frame = f
        previewView.frame = f
        editView.textContainer?.containerSize = NSSize(width: w - 18, height: CGFloat.greatestFiniteMagnitude)
        previewView.textContainer?.containerSize = NSSize(width: w - 18, height: CGFloat.greatestFiniteMagnitude)
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
        MemoStore.shared.update(id: memoId, text: editView.string)
        isClosing = true
        close()
        NotificationCenter.default.post(name: .memoDidHide, object: nil, userInfo: ["id": memoId])
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

// MARK: - TextView (编辑层)

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

// MARK: - Markdown 渲染器（完整版：去掉标记，生成纯渲染结果）

enum MarkdownRenderer {
    /// 渲染整段文本为带样式的 AttributedString（用于预览层）
    /// 渲染过程中会去掉所有 Markdown 标记符号（**、*、[red] 等）
    static func render(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = NSFont.systemFont(ofSize: 13)
        let defaultColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        let lines = text.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            if i > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(renderLine(line, baseFont: baseFont, defaultColor: defaultColor))
        }
        return result
    }

    private static func renderLine(_ line: String, baseFont: NSFont, defaultColor: NSColor) -> NSAttributedString {
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

        let nsRemaining = remaining as NSString
        let pattern = "(\\*\\*[^*]+\\*\\*)|(\\*[^*]+\\*)|(\\[red\\][^\\[]+\\[/red\\])|(\\[green\\][^\\[]+\\[/green\\])|(\\[blue\\][^\\[]+\\[/blue\\])"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: remaining, attributes: [.font: font, .foregroundColor: defaultColor])
        }

        let matches = regex.matches(in: remaining, range: NSRange(location: 0, length: nsRemaining.length))
        let result = NSMutableAttributedString()
        var lastEnd = 0

        for match in matches {
            if match.range.location > lastEnd {
                let plain = nsRemaining.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                result.append(NSAttributedString(string: plain, attributes: [.font: font, .foregroundColor: defaultColor]))
            }

            let matched = nsRemaining.substring(with: match.range)

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

        if lastEnd < nsRemaining.length {
            let tail = nsRemaining.substring(from: lastEnd)
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
