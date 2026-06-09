import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: MonitorState
    @AppStorage("updateInterval") private var updateInterval = 700
    @AppStorage("ocrTop") private var ocrTop = 95
    @AppStorage("ocrLeft") private var ocrLeft = 275
    @AppStorage("ocrWidth") private var ocrWidth = 180
    @AppStorage("ocrHeight") private var ocrHeight = 55
    @AppStorage("hotkeyCode") private var hotkeyCode = 37

    @State private var testResult: String = ""

    private let keyOptions: [(String, Int)] = [
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14),
        ("F", 3), ("G", 5), ("H", 4), ("I", 34), ("J", 38),
        ("K", 40), ("L (默认)", 37), ("M", 46), ("N", 29), ("O", 45),
        ("P", 31), ("Q", 35), ("R", 12), ("S", 15), ("T", 17),
        ("U", 32), ("V", 9), ("W", 13), ("X", 1), ("Y", 7), ("Z", 6)
    ]

    var body: some View {
        Form {
            Section("全局快捷键") {
                HStack {
                    Text("监控开关:")
                    Spacer()
                    Picker("", selection: $hotkeyCode) {
                        ForEach(keyOptions, id: \.1) { option in
                            Text("Cmd + \(option.0)").tag(option.1)
                        }
                    }
                    .frame(width: 140)
                    .labelsHidden()
                }
                Text("按此快捷键可随时开始/停止监控")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("OCR 区域 (包含股票名+均价+最新价)") {
                HStack {
                    LabeledContent("Top:") {
                        TextField("", value: $ocrTop, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    LabeledContent("Left:") {
                        TextField("", value: $ocrLeft, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }
                HStack {
                    LabeledContent("W:") {
                        TextField("", value: $ocrWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                    LabeledContent("H:") {
                        TextField("", value: $ocrHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                    }
                }

                HStack {
                    Button("📸 选择 OCR 区域") {
                        selectOCRRegion()
                    }
                    Button("🧪 测试 OCR") {
                        testOCR()
                    }
                }

                if !testResult.isEmpty {
                    Text(testResult)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("刷新设置") {
                LabeledContent("刷新间隔 (ms)") {
                    TextField("", value: $updateInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Section("关于") {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("2.0.0")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("日志目录")
                    Spacer()
                    Button(Logger.shared.logDirPath) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Logger.shared.logDirPath))
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 440)
        .onChange(of: updateInterval) { _ in saveConfig() }
        .onChange(of: ocrTop) { _ in saveConfig() }
        .onChange(of: ocrLeft) { _ in saveConfig() }
        .onChange(of: ocrWidth) { _ in saveConfig() }
        .onChange(of: ocrHeight) { _ in saveConfig() }
        .onChange(of: hotkeyCode) { _ in saveConfig() }
    }

    private func saveConfig() {
        state.config.updateInterval = updateInterval
        state.config.ocrRegion = ScreenRegion(top: ocrTop, left: ocrLeft, width: ocrWidth, height: ocrHeight)
        state.config.hotkeyCode = hotkeyCode
        state.config.save()

        NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
    }

    private func selectOCRRegion() {
        let panel = RegionSelectPanel()
        panel.onSelect = { region in
            ocrTop = region.top
            ocrLeft = region.left
            ocrWidth = region.width
            ocrHeight = region.height
            saveConfig()
        }
        panel.show()
    }

    private func testOCR() {
        let region = ScreenRegion(top: ocrTop, left: ocrLeft, width: ocrWidth, height: ocrHeight)
        let results = OCREngine.shared.recognize(region: region)
        if results.isEmpty {
            testResult = "未识别到任何文字，请调整区域"
            return
        }
        let parsed = OCREngine.shared.parseResults(results)
        var lines = ["原始文本: \(parsed.rawText)", ""]
        lines.append("股票名: \(parsed.name.isEmpty ? "(未识别)" : parsed.name)")
        lines.append("股票代码: \(parsed.code ?? "(未识别)")")
        lines.append("均价: \(parsed.avgPrice.map { String(format: "%.2f", $0) } ?? "(未识别)")")
        lines.append("最新价: \(parsed.currentPrice.map { String(format: "%.2f", $0) } ?? "(未识别)")")
        lines.append("")
        for r in results {
            lines.append("\"\(r.text)\" (\(Int(r.confidence * 100))%)")
        }
        testResult = lines.joined(separator: "\n")
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("hotkeyChanged")
}
