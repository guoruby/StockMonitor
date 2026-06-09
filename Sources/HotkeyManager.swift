import Cocoa
import Carbon

class HotkeyManager {
    static let shared = HotkeyManager()

    private var carbonHotKey: EventHotKeyRef?
    private var hotKeyID: EventHotKeyID?
    private var eventHandler: EventHandlerRef?
    private var currentKeyCode: UInt32 = 37
    private var currentModifiers: UInt32 = UInt32(cmdKey)

    private static let signature: FourCharCode = {
        var result: FourCharCode = 0
        for char in "SMhk".utf16 { result = (result << 8) + FourCharCode(char) }
        return result
    }()

    init() {
        installEventHandler()
        registerHotkey()
        NotificationCenter.default.addObserver(
            forName: .hotkeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reregister()
        }
    }

    deinit {
        unregisterHotkey()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    private func installEventHandler() {
        let eventSpec = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    UInt32(kEventParamDirectObject),
                    UInt32(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }
                guard hotKeyID.signature == HotkeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                Logger.shared.info("全局快捷键触发(Carbon)")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .toggleMonitoring, object: nil)
                }
                return noErr
            },
            1,
            eventSpec,
            nil,
            &eventHandler
        )
        Logger.shared.info("Carbon事件处理器已安装")
    }

    private func registerHotkey() {
        let keyCode = UInt32(MonitorState.shared.config.hotkeyCode)
        currentKeyCode = keyCode
        currentModifiers = UInt32(cmdKey)

        var hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: 1
        )
        var carbonHotKey: EventHotKeyRef?

        let error = RegisterEventHotKey(
            currentKeyCode,
            currentModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &carbonHotKey
        )

        if error == noErr, carbonHotKey != nil {
            self.carbonHotKey = carbonHotKey
            self.hotKeyID = hotKeyID
            Logger.shared.info("全局快捷键注册成功: Cmd+\(Self.keyName(currentKeyCode)) (keyCode=\(currentKeyCode))")
        } else {
            Logger.shared.error("全局快捷键注册失败: error=\(error), 可能被其他应用占用")
        }
    }

    private func unregisterHotkey() {
        if let ref = carbonHotKey {
            UnregisterEventHotKey(ref)
            carbonHotKey = nil
            hotKeyID = nil
            Logger.shared.info("全局快捷键已注销")
        }
    }

    func reregister() {
        unregisterHotkey()
        registerHotkey()
    }

    static func keyName(_ code: UInt32) -> String {
        switch code {
        case 0: return "A"; case 11: return "B"; case 8: return "C"
        case 2: return "D"; case 14: return "E"; case 3: return "F"
        case 5: return "G"; case 4: return "H"; case 34: return "I"
        case 38: return "J"; case 40: return "K"; case 37: return "L"
        case 46: return "M"; case 29: return "N"; case 45: return "O"
        case 31: return "P"; case 35: return "Q"; case 12: return "R"
        case 15: return "S"; case 17: return "T"; case 32: return "U"
        case 9: return "V"; case 13: return "W"; case 1: return "X"
        case 7: return "Y"; case 6: return "Z"
        default: return "\(code)"
        }
    }
}
