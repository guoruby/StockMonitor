import Cocoa

class MemoPanel: NSPanel {
    private let memoId: String
    private var textView: MemoTextView!
    private var closeBtn: NSButton!
    private var isClosing = false

    init(memo: MemoItem) {
        self.memoId = memo.id

        super.init(
            contentRect: NSRect(x: memo.x, y: memo.y, width: memo.width, height: memo.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        hasShadow = true

        setupContent(memo: memo)

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: self, queue: .main
        ) { [weak self] _ in
            self?.layoutSubviews()
        }
    }

    private func setupContent(memo: MemoItem) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: memo.width, height: memo.height))
        container.panel = self

        // 关闭按钮
        closeBtn = NSButton(frame: NSRect(x: memo.width - 18, y: memo.height - 18, width: 14, height: 14))
        closeBtn.isBordered = false
        closeBtn.wantsLayer = true
        closeBtn.layer?.backgroundColor = .clear
        let closeImg = NSImage(size: NSSize(width: 14, height: 14))
        closeImg.lockFocus()
        let c = NSColor(calibratedRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        c.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 11, y: 11))
        path.move(to: NSPoint(x: 11, y: 3))
        path.line(to: NSPoint(x: 3, y: 11))
        path.stroke()
        closeImg.unlockFocus()
        closeBtn.image = closeImg
        closeBtn.target = self
        closeBtn.action = #selector(closeMemo)
        container.addSubview(closeBtn)

        // 文本编辑区
        let textContainer = NSTextContainer()
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = MemoTextView(frame: NSRect(x: 6, y: 4, width: memo.width - 12, height: memo.height - 22),
                                textContainer: textContainer)
        textView.string = memo.text
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isFieldEditor = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.insertionPointColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.3, alpha: 1)
        textView.delegate = self
        container.addSubview(textView)

        contentView = container
    }

    @objc private func closeMemo() {
        isClosing = true
        savePosition()
        MemoStore.shared.remove(id: memoId)
        close()
        NotificationCenter.default.post(name: .memoDidClose, object: nil, userInfo: ["id": memoId])
    }

    func savePosition() {
        guard !isClosing else { return }
        let frame = contentRect(forFrameRect: self.frame)
        MemoStore.shared.update(
            id: memoId,
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    func saveText() {
        MemoStore.shared.update(id: memoId, text: textView.string)
    }

    private func layoutSubviews() {
        let w = contentView!.bounds.width
        let h = contentView!.bounds.height
        closeBtn.frame = NSRect(x: w - 18, y: h - 18, width: 14, height: 14)
        textView.frame = NSRect(x: 6, y: 4, width: w - 12, height: h - 22)
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
        let rect = bounds
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: rect.width, height: rect.height), xRadius: 6, yRadius: 6)
        NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
        path.fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        panel?.savePosition()
        super.mouseUp(with: event)
    }
}

// MARK: - TextView

class MemoTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" {
            return super.performKeyEquivalent(with: event)
        }
        return false
    }
}

// MARK: - Notification

extension Notification.Name {
    static let memoDidClose = Notification.Name("memoDidClose")
}
