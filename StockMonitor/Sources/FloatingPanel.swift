import Cocoa

class FloatingPanel: NSPanel {
    private let monitorState = MonitorState.shared
    private var contentView_: FloatingContentView!
    private var originalPos: NSPoint = .zero

    static let panelWidth: CGFloat = 118
    static let panelHeight: CGFloat = 22

    func show() {
        styleMask = [.titled, .closable, .miniaturizable]
        isFloatingPanel = false
        level = .normal
        title = "股票价格监控"
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        backgroundColor = .white

        let w = FloatingPanel.panelWidth
        let h = FloatingPanel.panelHeight
        contentView_ = FloatingContentView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        contentView_?.panel = self
        contentView = contentView_

        setContentSize(NSSize(width: w, height: h))
        minSize = frame.size
        maxSize = frame.size

        let config = monitorState.config
        let region = config.ocrRegion
        let screenFrame = NSScreen.main!.frame
        let posX = Double(region.left + region.width)
        let ocrTopY = screenFrame.height - Double(region.top) + 380.0
        let desiredContentRect = NSRect(x: posX, y: ocrTopY, width: Double(w), height: Double(h))
        let frameRect = self.frameRect(forContentRect: desiredContentRect)
        setFrame(frameRect, display: true)

        makeKeyAndOrderFront(nil)
        orderFrontRegardless()

        Logger.shared.info("浮动窗口已显示，尺寸 \(Int(w))x\(Int(h))，位置 x=\(Int(posX)) y=\(Int(ocrTopY))，OCR区域 top=\(region.top) screenHeight=\(Int(screenFrame.height))")
    }

    func toggleMonitoring() {
        monitorState.toggleMonitoring()
        updateWindowStyle()
    }

    func updateWindowStyle() {
        let savedContentRect = contentRect(forFrameRect: frame)
        if monitorState.isMonitoring {
            styleMask = [.borderless, .nonactivatingPanel, .utilityWindow]
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            ignoresMouseEvents = false
            let newFrame = frameRect(forContentRect: savedContentRect)
            setFrame(newFrame, display: true)
            orderFrontRegardless()
            Logger.shared.info("窗口切换到监控模式：置顶")
        } else {
            styleMask = [.titled, .closable, .miniaturizable]
            level = .normal
            collectionBehavior = []
            let newFrame = frameRect(forContentRect: savedContentRect)
            setFrame(newFrame, display: true)
            Logger.shared.info("窗口切换到普通模式：不置顶")
        }
    }

    func savePosition() {
        let contentRect = contentRect(forFrameRect: frame)
        monitorState.config.windowPosX = Double(contentRect.origin.x)
        monitorState.config.windowPosY = Double(contentRect.origin.y)
        monitorState.config.save()
    }

    func shakeWindow(dx: CGFloat, dy: CGFloat) {
        if originalPos.x == 0 && originalPos.y == 0 {
            originalPos = frame.origin
        }
        if dx == 0 && dy == 0 {
            setFrameOrigin(originalPos)
            originalPos = .zero
        } else {
            if originalPos.x == 0 && originalPos.y == 0 {
                originalPos = frame.origin
            }
            setFrameOrigin(NSPoint(x: originalPos.x + dx, y: originalPos.y + dy))
        }
    }
}

class FloatingContentView: NSView {
    weak var panel: FloatingPanel?
    private var dragStartPos: NSPoint = .zero
    private var isDragging: Bool = false

    private var deviationField: NSTextField!
    private var signalField: NSTextField!
    private var toggleBtn: NSButton!

    private var monitorState = MonitorState.shared
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        startUpdateTimer()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.96).cgColor
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        layer?.borderColor = NSColor(calibratedWhite: 0.85, alpha: 1).cgColor
        layer?.borderWidth = 0.5

        deviationField = NSTextField(labelWithString: "--%")
        deviationField.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        deviationField.textColor = NSColor(calibratedRed: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        deviationField.alignment = .left
        deviationField.drawsBackground = false
        deviationField.isBezeled = false
        addSubview(deviationField)

        signalField = NSTextField(labelWithString: "--")
        signalField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        signalField.textColor = NSColor(calibratedRed: 0.3, green: 0.3, blue: 0.35, alpha: 1)
        signalField.alignment = .center
        signalField.drawsBackground = false
        signalField.isBezeled = false
        addSubview(signalField)

        toggleBtn = NSButton(frame: .zero)
        toggleBtn.isBordered = false
        toggleBtn.wantsLayer = true
        toggleBtn.layer?.backgroundColor = .clear
        updateToggleIcon()
        toggleBtn.target = self
        toggleBtn.action = #selector(toggleMonitoring)
        addSubview(toggleBtn)

        layoutAll()
    }

    private func layoutAll() {
        let w = bounds.width
        let h = bounds.height
        let cy: CGFloat = (h - 12) / 2

        deviationField.frame = NSRect(x: 4, y: cy, width: 52, height: 14)
        signalField.frame = NSRect(x: 55, y: cy, width: 44, height: 14)
        toggleBtn.frame = NSRect(x: w - 16, y: cy, width: 12, height: 12)
    }

    override func layout() {
        super.layout()
        layoutAll()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        if let window = self.window {
            dragStartPos = NSEvent.mouseLocation
            dragStartPos.x -= window.frame.origin.x
            dragStartPos.y -= window.frame.origin.y
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let window = self.window else { return }
        let currentLocation = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(
            x: currentLocation.x - dragStartPos.x,
            y: currentLocation.y - dragStartPos.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        panel?.savePosition()
    }

    @objc private func toggleMonitoring() {
        panel?.toggleMonitoring()
    }

    private func updateToggleIcon() {
        let isMonitoring = monitorState.isMonitoring
        let icon = NSImage(size: NSSize(width: 12, height: 12))
        icon.lockFocus()

        if isMonitoring {
            let c = NSColor(calibratedRed: 1, green: 0.35, blue: 0.35, alpha: 1)
            c.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 3, y: 2))
            path.line(to: NSPoint(x: 3, y: 10))
            path.move(to: NSPoint(x: 9, y: 2))
            path.line(to: NSPoint(x: 9, y: 10))
            path.stroke()
        } else {
            let c = NSColor(calibratedRed: 0.2, green: 0.6, blue: 1, alpha: 1)
            c.setFill()
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: 2))
            path.line(to: NSPoint(x: 2, y: 10))
            path.line(to: NSPoint(x: 10, y: 6))
            path.close()
            path.fill()
        }

        icon.unlockFocus()
        toggleBtn.image = icon
    }

    private func startUpdateTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.refreshDisplay()
        }
    }

    private func refreshDisplay() {
        let state = monitorState

        if state.isCircuitBreaker {
            deviationField.stringValue = "熔断"
            deviationField.textColor = NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
            signalField.stringValue = ""
        } else if state.ocrFailCount > 0 && state.isMonitoring {
            deviationField.stringValue = "失败"
            deviationField.textColor = NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)
            signalField.stringValue = ""
        } else {
            // 偏离度（颜色由正负决定）
            if state.deviationPercent >= 0 {
                deviationField.stringValue = String(format: "+%.1f%%", state.deviationPercent)
                deviationField.textColor = NSColor.red
            } else {
                deviationField.stringValue = String(format: "%.1f%%", state.deviationPercent)
                deviationField.textColor = NSColor(calibratedRed: 0, green: 0.67, blue: 0, alpha: 1)
            }

            // 买卖信号 + 置信度 + 箭头
            if state.buySignal {
                signalField.stringValue = "B\(state.patternConfidence)↑"
                signalField.textColor = NSColor(calibratedRed: 0.85, green: 0.15, blue: 0.15, alpha: 1)
            } else if state.sellSignal {
                signalField.stringValue = "S\(state.patternConfidence)↓"
                signalField.textColor = NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
            } else if state.signal == "limit_up" {
                signalField.stringValue = "★"
                signalField.textColor = NSColor.red
            } else if state.signal == "limit_down" {
                signalField.stringValue = "↓"
                signalField.textColor = NSColor(calibratedRed: 0, green: 0.55, blue: 0, alpha: 1)
            } else {
                signalField.stringValue = "→"
                signalField.textColor = NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.5, alpha: 1)
            }
        }

        updateToggleIcon()
    }

    deinit {
        timer?.invalidate()
    }
}
