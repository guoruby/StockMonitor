import SwiftUI
import Combine

class MonitorState: ObservableObject {
    static let shared = MonitorState()

    @Published var isMonitoring: Bool = false
    @Published var currentPrice: Double = 0
    @Published var avgPrice: Double = 0
    @Published var ocrAvgPrice: Double = 0
    @Published var ocrCurrentPrice: Double = 0
    @Published var deviation: Double = 0
    @Published var deviationPercent: Double = 0
    @Published var stockName: String = "--"
    @Published var stockCode: String = ""
    @Published var lastUpdateTime: String = "--:--:--"
    @Published var isCircuitBreaker: Bool = false
    @Published var ocrFailCount: Int = 0
    @Published var vwap: Double = 0
    @Published var changePct: Double = 0
    @Published var volRatio: Double = 1.0
    @Published var volumeStatus: String = "平量"
    @Published var signal: String = "neutral"
    @Published var pattern: String = "normal"
    @Published var patternReason: String = ""
    @Published var patternConfidence: Int = 50
    @Published var recommendation: String = "hold"
    @Published var tradingPeriod: String = "--"
    @Published var isShaking: Bool = false
    @Published var statusMessage: String = "就绪"
    @Published var amplitude: Double = 0
    @Published var trendText: String = "--"
    @Published var buySignal: Bool = false
    @Published var sellSignal: Bool = false

    var config: AppConfig = AppConfig.load()
    private var timer: Timer?
    private var shakeTimer: Timer?
    private var shakeStep: Int = 0
    private var nameToCodeCache: [String: String] = [:]

    func toggleMonitoring() {
        isMonitoring.toggle()
        NotificationCenter.default.post(name: .monitoringStateChanged, object: nil)
        if isMonitoring {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    func startMonitoring() {
        Logger.shared.info("开始监控，间隔=\(config.updateInterval)ms")
        timer = Timer.scheduledTimer(withTimeInterval: Double(config.updateInterval) / 1000.0, repeats: true) { [weak self] _ in
            self?.updateData()
        }
        updateData()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        stopShaking()
        statusMessage = "已停止"
        Logger.shared.info("停止监控")
    }

    private func updateData() {
        if isCircuitBreaker { return }
        updateOCRMode()
    }

    private func updateOCRMode() {
        let ocrRegion = config.ocrRegion
        let ocrResults = OCREngine.shared.recognize(region: ocrRegion)
        let parsed = OCREngine.shared.parseResults(ocrResults)

        let ocrPrice = parsed.currentPrice
        let ocrAvg = parsed.avgPrice

        if ocrPrice == nil || ocrAvg == nil || (ocrAvg ?? 0) <= 0 {
            ocrFailCount += 1
            Logger.shared.error("OCR识别失败(第\(ocrFailCount)次)")
            if ocrFailCount >= 3 {
                isCircuitBreaker = true
                ocrCurrentPrice = 0
                ocrAvgPrice = 0
                deviation = 0
                deviationPercent = 0
                currentPrice = 0
                avgPrice = 0
                Logger.shared.error("OCR连续失败\(ocrFailCount)次，触发熔断")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self.isCircuitBreaker = false
                    self.ocrFailCount = 0
                }
            }
            return
        }

        ocrFailCount = 0
        ocrCurrentPrice = ocrPrice!
        ocrAvgPrice = ocrAvg!
        deviation = ocrCurrentPrice - ocrAvgPrice
        deviationPercent = ocrAvgPrice > 0 ? (deviation / ocrAvgPrice) * 100 : 0
        currentPrice = ocrCurrentPrice
        avgPrice = ocrAvg!
        lastUpdateTime = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)

        Logger.shared.info("OCR偏离: 最新=\(String(format: "%.2f", ocrCurrentPrice)) 均价=\(String(format: "%.2f", ocrAvgPrice)) 偏离=\(String(format: "%.2f", deviationPercent))%")

        if abs(deviationPercent) >= 4.0 { startShaking() } else { stopShaking() }
        statusMessage = "更新: \(lastUpdateTime)"

        let detectedName = parsed.name
        let detectedCode = parsed.code

        if !detectedName.isEmpty {
            stockName = detectedName
        }

        if let code = detectedCode {
            stockCode = code
            fetchAPIData(code: code)
        } else if !detectedName.isEmpty {
            if let cached = nameToCodeCache[detectedName] {
                stockCode = cached
                Logger.shared.info("名称缓存命中: \(detectedName) -> \(cached)")
                fetchAPIData(code: cached)
            } else {
                let searchName = detectedName
                APIService.shared.searchStockCode(name: searchName) { [weak self] foundCode in
                    guard let self = self else { return }
                    if let foundCode = foundCode {
                        self.nameToCodeCache[searchName] = foundCode
                        DispatchQueue.main.async {
                            self.stockCode = foundCode
                            Logger.shared.info("名称查询成功: \(searchName) -> \(foundCode)")
                            self.fetchAPIData(code: foundCode)
                        }
                    } else {
                        Logger.shared.error("名称查询失败: \(searchName)")
                    }
                }
            }
        } else {
            Logger.shared.info("API未调用: OCR未识别到名称")
        }
    }

    private func fetchAPIData(code: String) {
        // 同时请求实时行情和分时数据
        APIService.shared.fetchRealtimeData(stockCode: code) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                // 获取分时数据
                APIService.shared.fetchMinuteData(stockCode: code) { [weak self] minuteData in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.vwap = data.vwap
                        self.changePct = data.changePct
                        self.volRatio = data.volRatio
                        self.volumeStatus = data.volRatio > 1.5 ? "放量" : data.volRatio < 0.7 ? "缩量" : "平量"
                        self.tradingPeriod = data.tradingPeriod
                        self.amplitude = data.amplitude

                        // 计算趋势指标
                        let trend: TrendIndicators
                        if let minuteData = minuteData, minuteData.count >= 2 {
                            trend = VWAPAnalyzer.calcTrendFromMinute(minuteData, prevClose: data.prevClose)
                            Logger.shared.info("趋势指标: VWAP=\(trend.vwap) 零轴=\(String(format: "%.2f", trend.vwapVsZero))% 斜率=\(trend.slope) 加速度=\(trend.acceleration) 近期量比=\(trend.volRatioRecent)")
                        } else {
                            // 降级：用实时行情的VWAP
                            let vwapVsZero = data.prevClose > 0 ? (data.vwap - data.prevClose) / data.prevClose * 100 : 0
                            trend = TrendIndicators(vwap: data.vwap, vwapVsZero: vwapVsZero, slope: 0, acceleration: 0,
                                                    vwapTrend: "unknown", recentAvgVol: 0, overallAvgVol: 0,
                                                    volRatioRecent: data.volRatio)
                            Logger.shared.info("分时数据不足，降级使用实时VWAP")
                        }

                        let analysis = VWAPAnalyzer.analyze(data: data, trend: trend)
                        self.signal = analysis.signal
                        self.pattern = analysis.pattern
                        self.patternReason = analysis.reason
                        self.patternConfidence = analysis.confidence
                        self.recommendation = analysis.recommendation
                        self.buySignal = analysis.buySignal
                        self.sellSignal = analysis.sellSignal

                        switch analysis.signal {
                        case "strong": self.trendText = "↑ 多头"
                        case "sell", "weak", "limit_down": self.trendText = "↓ 空头"
                        case "limit_up": self.trendText = "★ 涨停"
                        default: self.trendText = "→ 震荡"
                        }

                        Logger.shared.info("信号: \(analysis.signal) 形态=\(analysis.pattern) 置信=\(analysis.confidence) 原因=\(analysis.reason)")
                    }
                }

            case .failure(let error):
                Logger.shared.error("API调用失败: \(error.localizedDescription)")
            }
        }
    }

    func startShaking() {
        guard !isShaking else { return }
        isShaking = true
        shakeStep = 0
        let offsets: [(CGFloat, CGFloat)] = [(1, 1), (-1, -1), (1, -1), (-1, 1), (0, 0)]
        shakeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let offset = offsets[self.shakeStep % offsets.count]
            NotificationCenter.default.post(name: .shakeWindow, object: nil, userInfo: ["dx": offset.0, "dy": offset.1])
            self.shakeStep += 1
        }
    }

    func stopShaking() {
        isShaking = false
        shakeTimer?.invalidate()
        shakeTimer = nil
        NotificationCenter.default.post(name: .shakeWindow, object: nil, userInfo: ["dx": CGFloat(0), "dy": CGFloat(0)])
    }
}

extension Notification.Name {
    static let shakeWindow = Notification.Name("shakeWindow")
    static let monitoringStateChanged = Notification.Name("monitoringStateChanged")
    static let toggleMonitoring = Notification.Name("toggleMonitoring")
    static let openSettings = Notification.Name("openSettings")
}
