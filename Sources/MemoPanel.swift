import Cocoa

class MemoPanel: NSPanel {
    private let memoId: String
    private var textView: MemoTextView!
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

    private func setupContent(memo: MemoItem) {
        let container = MemoContainerView(frame: NSRect(x: 0, y: 0, width: memo.width, height: memo.height))
        container.panel = self

        let textContainer = NSTextContainer(containerSize: NSSize(width: memo.width - 12, height: .greatestFiniteMagnitude))
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = MemoTextView(frame: NSRect(x: 6, y: 4, width: memo.width - 12, height: memo.height - 8),
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
        textView.panel = self // 让textView能通知窗口拖拽
        container.addSubview(textView)

        contentView = container
    }

    @objc private func closeMemo() {
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
        MemoStore.shared.update(
            id: memoId,
            x: frame.origin.x, y: frame.origin.y,
            width: frame.width, height: frame.height
        )
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

    private func layoutSubviews() {
        guard let cv = contentView else { return }
        let w = cv.bounds.width
        let h = cv.bounds.height
        textView.frame = NSRect(x: 6, y: 4, width: w - 12, height: h - 8)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "关闭便签", action: #selector(closeMemo), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isCmdDragging {
            panel?.continueCmdDrag(NSEvent.mouseLocation)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isCmdDragging {
            isCmdDragging = false
            panel?.endCmdDrag()
        }
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
