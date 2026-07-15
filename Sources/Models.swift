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

struct MinuteData {
    let time: String
    let price: Double
    let cumVol: Int       // 累计成交量(手)
    let cumAmt: Double    // 累计成交额(元)
    let minuteVol: Int    // 当分钟成交量(手)
}

// 量价背离卖点策略数据（10:14-10:46窗口内，分时均线+量比+时间窗口三维判断）
struct DivergenceData {
    let inWindow: Bool              // 是否在10:14-10:46时间窗口内
    let yesterdayMaxVol: Int        // 昨日全天最大分钟成交量
    let yesterdayCumVolToNow: Int   // 昨日开盘到当前时刻的累计成交量
    let earlyVwapMax: Double        // 早盘10分钟(9:30-9:39)内VWAP最大值
    let todayMaxMinuteVol: Int      // 今日最大分钟成交量
    let currentCumVol: Int          // 今日截至当前累计成交量
    let top10DistanceThreshold: Double // 今日所有分钟线价格偏离VWAP的第10大值(%)，当前偏离>=此值即为Top10
}

struct TrendIndicators {
    let vwap: Double
    let vwapVsZero: Double    // VWAP相对昨收价%
    let slope: Double         // 均价斜率(元/分钟)
    let acceleration: Double  // 均价加速度(元/分钟²)
    let vwapTrend: String     // up/down/flat/unknown
    let recentAvgVol: Double  // 近N分钟均量(手)
    let overallAvgVol: Double // 全天均量(手)
    let volRatioRecent: Double // 近期量/全天均量
    let volPeakRatio: Double  // 近期峰值量/全天峰值量
}

struct StockData {
    let name: String
    let code: String
    let price: Double
    let prevClose: Double
    let vwap: Double
    let changePct: Double
    let volume: Int
    let amount: Double
    let volRatio: Double
    let open: Double
    let high: Double
    let low: Double
    let tradingPeriod: String
    let amplitude: Double
    let upLimit: Double
    let downLimit: Double
    let maxVwapDistance: Double  // 历史最大VWAP偏离(%)
    let dayLowDistance: Double   // 距全天最低点距离(%)
    let minutesSinceHigh: Int    // 距上次刷新新高的分钟数
    let minutesSinceVolHigh: Int // 距上次量能创新高的分钟数
    let divergence: DivergenceData? // 量价背离卖点策略数据
}

struct VWAPAnalysis {
    let signal: String        // strong/sell/weak/neutral/limit_up/limit_down
    let recommendation: String // buy/sell/hold/avoid
    let pattern: String
    let reason: String
    let confidence: Int
    let volumeStatus: String
    let buySignal: Bool
    let sellSignal: Bool
    let divergenceSell: Bool  // 量价背离卖点触发
}

struct MemoItem: Codable {
    let id: String
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var createdAt: String
}
