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
    let top10Threshold: Double // 今日所有分钟线偏离(含负)中第10大值(%)，当前偏离>=此值即排前10
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

// 压力支撑位设置
struct PriceLevel: Codable {
    var support: Double      // 支撑位价格
    var pressure: Double     // 压力位价格
    var validDate: String    // 生效日期 YYYYMMDD
    var createdAt: String    // 创建时间

    func isExpired() -> Bool {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        guard let valid = formatter.date(from: validDate) else { return true }
        // 有效期到生效日期当天收盘(15:00)
        let expiry = valid.addingTimeInterval(15 * 3600)
        return Date() > expiry
    }
}

// 压力支撑位存储（持久化到文件）
class PriceLevelStore: ObservableObject {
    static let shared = PriceLevelStore()

    @Published var hs300Level: PriceLevel?
    @Published var stockLevels: [String: PriceLevel] = [:]  // key: stockCode

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StockMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("price_levels.json")
    }

    init() {
        load()
    }

    private struct StoreData: Codable {
        var hs300Level: PriceLevel?
        var stockLevels: [String: PriceLevel]
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let store = try? JSONDecoder().decode(StoreData.self, from: data) else { return }
        // 过滤过期数据
        hs300Level = store.hs300Level?.isExpired() == false ? store.hs300Level : nil
        for (k, v) in store.stockLevels {
            if !v.isExpired() { stockLevels[k] = v }
        }
    }

    func save() {
        let store = StoreData(hs300Level: hs300Level, stockLevels: stockLevels)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL)
        }
    }

    // 设置沪深300压力支撑位
    // - 收盘后(>15:00)设置 → 下一交易日生效
    // - 盘前/盘中设置 → 当天生效
    func setHS300Level(support: Double, pressure: Double) {
        let validDate = Self.calcValidDate()
        hs300Level = PriceLevel(support: support, pressure: pressure, validDate: validDate,
                                createdAt: ISO8601DateFormatter().string(from: Date()))
        save()
    }

    // 设置个股压力支撑位
    func setStockLevel(code: String, support: Double, pressure: Double) {
        let validDate = Self.calcValidDate()
        stockLevels[code] = PriceLevel(support: support, pressure: pressure, validDate: validDate,
                                       createdAt: ISO8601DateFormatter().string(from: Date()))
        save()
    }

    // 获取个股当前有效的压力支撑位（含沪深300作为大盘参考）
    func getStockLevel(code: String) -> PriceLevel? {
        if let level = stockLevels[code], !level.isExpired() {
            return level
        }
        return nil
    }

    // 计算生效日期：收盘后设置 → 下一交易日，盘前/盘中设置 → 当天
    private static func calcValidDate() -> String {
        let cal = Calendar(identifier: .gregorian)
        let now = Date()
        var shanghaiCal = cal
        shanghaiCal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let hh = shanghaiCal.component(.hour, from: now)
        let mm = shanghaiCal.component(.minute, from: now)
        let hhmm = hh * 100 + mm

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")

        // 收盘后(>15:00) → 下一交易日
        if hhmm > 1500 {
            // 找下一个工作日（跳过周末）
            for i in 1...7 {
                if let nextDay = shanghaiCal.date(byAdding: .day, value: i, to: now) {
                    let weekday = shanghaiCal.component(.weekday, from: nextDay)
                    if weekday != 1 && weekday != 7 {  // 1=周日, 7=周六
                        return formatter.string(from: nextDay)
                    }
                }
            }
        }
        return formatter.string(from: now)
    }
}
