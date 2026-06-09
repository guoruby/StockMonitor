import Cocoa
import Quartz

class RegionSelectPanel: NSObject {
    var onSelect: ((ScreenRegion) -> Void)?
    var onCancel: (() -> Void)?
    private var panel: NSPanel!
    private var imageView: RegionSelectImageView!
    private var retainedSelf: RegionSelectPanel?

    func show() {
        retainedSelf = self

        let displayID = CGMainDisplayID()
        let mainScreen = NSScreen.main!
        let frame = mainScreen.frame

        guard let img = CGDisplayCreateImage(displayID) else {
            Logger.shared.error("区域选择: 截图失败")
            retainedSelf = nil
            return
        }

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        imageView = RegionSelectImageView(frame: NSRect(origin: .zero, size: frame.size))
        imageView.screenshot = img
        imageView.scaleFactor = mainScreen.backingScaleFactor
        imageView.onSelect = { [weak self] region in
            self?.panel.close()
            self?.onSelect?(region)
            self?.retainedSelf = nil
        }
        imageView.onCancel = { [weak self] in
            self?.panel.close()
            self?.onCancel?()
            self?.retainedSelf = nil
        }

        panel.contentView = imageView
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        Logger.shared.info("区域选择面板已显示")
    }
}

class RegionSelectImageView: NSView {
    var screenshot: CGImage?
    var scaleFactor: CGFloat = 2.0
    var onSelect: ((ScreenRegion) -> Void)?
    var onCancel: (() -> Void)?

    private var isDragging = false
    private var startPoint: NSPoint = .zero
    private var currentRect: NSRect = .zero
    private var selectedRegion: ScreenRegion?
    private var confirmBtn: NSButton!
    private var cancelBtn: NSButton!
    private var exitBtn: NSButton!
    private var hasSelection = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupButtons()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    private func setupButtons() {
        confirmBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        confirmBtn.title = "确认"
        confirmBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        confirmBtn.bezelStyle = .rounded
        confirmBtn.wantsLayer = true
        confirmBtn.layer?.backgroundColor = NSColor.systemBlue.cgColor
        confirmBtn.layer?.cornerRadius = 6
        confirmBtn.contentTintColor = .white
        confirmBtn.isHidden = true
        confirmBtn.target = self
        confirmBtn.action = #selector(confirmSelection)
        addSubview(confirmBtn)

        cancelBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        cancelBtn.title = "重选"
        cancelBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        cancelBtn.bezelStyle = .rounded
        cancelBtn.wantsLayer = true
        cancelBtn.layer?.backgroundColor = NSColor(white: 0.3, alpha: 1.0).cgColor
        cancelBtn.layer?.cornerRadius = 6
        cancelBtn.contentTintColor = .white
        cancelBtn.isHidden = true
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelSelection)
        addSubview(cancelBtn)

        exitBtn = NSButton(frame: NSRect(x: 0, y: 0, width: 70, height: 28))
        exitBtn.title = "退出"
        exitBtn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        exitBtn.bezelStyle = .rounded
        exitBtn.wantsLayer = true
        exitBtn.layer?.backgroundColor = NSColor.systemRed.cgColor
        exitBtn.layer?.cornerRadius = 6
        exitBtn.contentTintColor = .white
        exitBtn.target = self
        exitBtn.action = #selector(exitSelection)
        addSubview(exitBtn)

        positionExitButton()
    }

    private func positionExitButton() {
        exitBtn.frame = NSRect(x: bounds.width / 2 - 35, y: 20, width: 70, height: 28)
    }

    private func positionButtons() {
        guard hasSelection && currentRect.width > 0 && currentRect.height > 0 else {
            confirmBtn.isHidden = true
            cancelBtn.isHidden = true
            positionExitButton()
            return
        }

        let btnY = currentRect.origin.y - 36
        let btnX = currentRect.origin.x + currentRect.width - 148

        confirmBtn.frame = NSRect(x: btnX + 78, y: max(4, btnY), width: 70, height: 28)
        cancelBtn.frame = NSRect(x: btnX, y: max(4, btnY), width: 70, height: 28)
        confirmBtn.isHidden = false
        cancelBtn.isHidden = false
        exitBtn.isHidden = hasSelection
    }

    override func layout() {
        super.layout()
        positionExitButton()
        if hasSelection {
            positionButtons()
        }
    }

    @objc private func confirmSelection() {
        guard let region = selectedRegion else { return }
        Logger.shared.info("区域选择: 确认 top=\(region.top) left=\(region.left) \(region.width)x\(region.height)")
        onSelect?(region)
    }

    @objc private func cancelSelection() {
        hasSelection = false
        currentRect = .zero
        selectedRegion = nil
        confirmBtn.isHidden = true
        cancelBtn.isHidden = true
        exitBtn.isHidden = false
        needsDisplay = true
        Logger.shared.info("区域选择: 取消选择，重新拖拽")
    }

    @objc private func exitSelection() {
        Logger.shared.info("区域选择: 退出，不保存")
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let img = screenshot {
            let imgRect = NSRect(x: 0, y: 0, width: CGFloat(img.width) / scaleFactor, height: CGFloat(img.height) / scaleFactor)
            ctx.draw(img, in: imgRect)
        }

        ctx.setFillColor(NSColor(white: 0, alpha: 0.4).cgColor)
        ctx.fill(bounds)

        if currentRect.width > 0 && currentRect.height > 0 {
            ctx.clear(currentRect)
            if let img = screenshot {
                let srcRect = NSRect(
                    x: currentRect.origin.x * scaleFactor,
                    y: (bounds.height - currentRect.origin.y - currentRect.height) * scaleFactor,
                    width: currentRect.width * scaleFactor,
                    height: currentRect.height * scaleFactor
                )
                if let cropped = img.cropping(to: srcRect) {
                    ctx.draw(cropped, in: currentRect)
                } else {
                    ctx.draw(img, in: currentRect)
                }
            }

            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(currentRect)

            let sizeText = "\(Int(currentRect.width)) x \(Int(currentRect.height))"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let sizeAttrStr = NSAttributedString(string: sizeText, attributes: attrs)
            let textSize = sizeAttrStr.size()
            let textRect = NSRect(
                x: currentRect.origin.x + 4,
                y: currentRect.origin.y + currentRect.height - textSize.height - 4,
                width: textSize.width + 8,
                height: textSize.height + 4
            )
            ctx.setFillColor(NSColor(white: 0, alpha: 0.7).cgColor)
            ctx.fill(textRect)
            sizeAttrStr.draw(in: NSRect(x: textRect.origin.x + 4, y: textRect.origin.y + 2, width: textSize.width, height: textSize.height))
        }

        if !hasSelection {
            let instruction = "拖动选择包含「股票名+均价+最新价」的区域"
            let attrs2: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .bold),
                .foregroundColor: NSColor.systemYellow
            ]
            let instrStr = NSAttributedString(string: instruction, attributes: attrs2)
            let instrSize = instrStr.size()
            instrStr.draw(in: NSRect(x: (bounds.width - instrSize.width) / 2, y: bounds.height - 40, width: instrSize.width, height: instrSize.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let clickPos = convert(event.locationInWindow, from: nil)
        if hasSelection && currentRect.contains(clickPos) {
            isDragging = true
            startPoint = clickPos
            return
        }
        if hasSelection {
            hasSelection = false
            currentRect = .zero
            selectedRegion = nil
            confirmBtn.isHidden = true
            cancelBtn.isHidden = true
            exitBtn.isHidden = false
            needsDisplay = true
        }
        isDragging = true
        startPoint = clickPos
        currentRect = NSRect(x: startPoint.x, y: startPoint.y, width: 0, height: 0)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let current = convert(event.locationInWindow, from: nil)

        if hasSelection {
            let dx = current.x - startPoint.x
            let dy = current.y - startPoint.y
            currentRect.origin.x += dx
            currentRect.origin.y += dy
            startPoint = current
        } else {
            let x = min(startPoint.x, current.x)
            let y = min(startPoint.y, current.y)
            let w = abs(current.x - startPoint.x)
            let h = abs(current.y - startPoint.y)
            currentRect = NSRect(x: x, y: y, width: w, height: h)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if !hasSelection {
            if currentRect.width < 20 || currentRect.height < 10 {
                currentRect = .zero
                needsDisplay = true
                return
            }
            hasSelection = true
            selectedRegion = convertToScreenRegion(currentRect)
            positionButtons()
            Logger.shared.info("区域选择: \(Int(currentRect.width))x\(Int(currentRect.height))")
        } else {
            selectedRegion = convertToScreenRegion(currentRect)
            positionButtons()
        }
        needsDisplay = true
    }

    private func convertToScreenRegion(_ rect: NSRect) -> ScreenRegion {
        let screenFrame = NSScreen.main!.frame
        let flippedY = screenFrame.height - rect.origin.y - rect.height
        return ScreenRegion(
            top: Int(flippedY),
            left: Int(rect.origin.x),
            width: Int(rect.width),
            height: Int(rect.height)
        )
    }
}
