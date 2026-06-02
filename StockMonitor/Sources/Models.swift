import Foundation
import Cocoa

struct AppConfig: Codable {
    var ocrRegion: ScreenRegion
    var stockCode: String
    var updateInterval: Int
    var windowPosX: Double
    var windowPosY: Double
    var hotkeyCode: Int

    static func load() -> AppConfig {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StockMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")

        if let data = try? Data(contentsOf: file),
           let config = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return config
        }
        return AppConfig(
            ocrRegion: ScreenRegion(top: 95, left: 275, width: 180, height: 55),
            stockCode: "",
            updateInterval: 700,
            windowPosX: 574,
            windowPosY: 401,
            hotkeyCode: 37
        )
    }

    func save() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StockMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("config.json")
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: file)
        }
    }
}

struct ScreenRegion: Codable {
    var top: Int
    var left: Int
    var width: Int
    var height: Int

    var cgRect: CGRect {
        CGRect(x: left, y: top, width: width, height: height)
    }
}

struct OCRResult {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

struct ParsedOCR {
    let code: String?
    let name: String
    let avgPrice: Double?
    let currentPrice: Double?
    let rawText: String
}

struct StockData {
    let name: String
    let code: String
    let price: Double
    let vwap: Double
    let changePct: Double
    let volume: Int
    let amount: Double
    let volRatio: Double
    let flowStrength: Double
    let buyPressure: Int
    let sellPressure: Int
    let pressureRatio: Double
    let open: Double
    let high: Double
    let low: Double
    let tradingPeriod: String
    let amplitude: Double
}

struct VWAPAnalysis {
    let signal: String
    let recommendation: String
    let pattern: String
    let reason: String
    let confidence: Int
    let volumeStatus: String
    let moneySignal: Int
}
