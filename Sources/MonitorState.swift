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

    // 量价背离卖点策略状态
    private var yesterdayDataCache: [String: [MinuteData]] = [:]
    private var yesterdayFetchingCodes: Set<String> = []
    private var divergenceTriggered: Bool = false
    private var divergenceTriggerTime: Date?
    private var lastFetchCode: String = ""

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
        // 换股时清除量价背离状态
        if code != lastFetchCode {
            divergenceTriggered = false
            divergenceTriggerTime = nil
            lastFetchCode = code
        }

        // 异步获取昨日分时数据（仅首次，之后从缓存读取）
        if yesterdayDataCache[code] == nil && !yesterdayFetchingCodes.contains(code) {
            yesterdayFetchingCodes.insert(code)
            APIService.shared.fetchYesterdayMinuteData(stockCode: code) { [weak self] result in
                guard let self = self else { return }
                if let result = result {
                    self.yesterdayDataCache[code] = result
                    Logger.shared.info("昨日分时数据已缓存: \(code) 共\(result.count)条")
                }
                self.yesterdayFetchingCodes.remove(code)
            }
        }

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
                                                    volRatioRecent: data.volRatio, volPeakRatio: 1.0)
                            Logger.shared.info("分时数据不足，降级使用实时VWAP")
                        }

                        // 计算回踩企稳指标：最大VWAP偏离、距全天最低点距离
                        var maxVwapDistance = 0.0
                        var dayLowDistance = 0.0
                        var minutesSinceHigh = 0
                        var minutesSinceVolHigh = 0
                        if let minuteData = minuteData, minuteData.count >= 2, data.vwap > 0 {
                            let dayLow = minuteData.map { $0.price }.min() ?? data.price
                            dayLowDistance = dayLow > 0 ? (data.price - dayLow) / dayLow * 100 : 0
                            var highestPrice = 0.0
                            var lastHighIdx = 0
                            var highestVol = 0
                            var lastVolHighIdx = 0
                            for (i, m) in minuteData.enumerated() {
                                if m.price > highestPrice {
                                    highestPrice = m.price
                                    lastHighIdx = i
                                }
                                if m.minuteVol > highestVol {
                                    highestVol = m.minuteVol
                                    lastVolHighIdx = i
                                }
                                if m.cumVol > 0 && m.price > 0 {
                                    let mVwap = m.cumAmt / (Double(m.cumVol) * 100.0)
                                    let mDist = mVwap > 0 ? (m.price - mVwap) / mVwap * 100 : 0
                                    if mDist > maxVwapDistance {
                                        maxVwapDistance = mDist
                                    }
                                }
                            }
                            minutesSinceHigh = minuteData.count - 1 - lastHighIdx
                            minutesSinceVolHigh = minuteData.count - 1 - lastVolHighIdx
                        }

                        // 量价背离卖点指标（10:14-10:46窗口）
                        var divergenceData: DivergenceData? = nil
                        let divCal = Calendar.current
                        let divHH = divCal.component(.hour, from: Date())
                        let divMM = divCal.component(.minute, from: Date())
                        let currentHHMM = divHH * 100 + divMM
                        let inWindow = currentHHMM >= 1014 && currentHHMM <= 1046

                        if inWindow, let yData = self.yesterdayDataCache[code] {
                            var todayMaxVol = 0
                            var curCumVol = 0
                            var earlyVMax = 0.0
                            var priceDistances: [Double] = []
                            if let mData = minuteData {
                                for m in mData {
                                    if m.minuteVol > todayMaxVol { todayMaxVol = m.minuteVol }
                                    curCumVol = m.cumVol
                                    if let t = Int(m.time), t >= 930 && t <= 939, m.cumVol > 0 {
                                        let v = m.cumAmt / (Double(m.cumVol) * 100.0)
                                        if v > earlyVMax { earlyVMax = v }
                                    }
                                    // 收集每根分钟线的价格偏离VWAP百分比（只收集正偏离：价格高于均线）
                                    if m.cumVol > 0 {
                                        let mVwap = m.cumAmt / (Double(m.cumVol) * 100.0)
                                        if mVwap > 0 {
                                            let dist = (m.price - mVwap) / mVwap * 100
                                            if dist > 0 { priceDistances.append(dist) }
                                        }
                                    }
                                }
                            }
                            // Top10阈值：降序后取第10大，不足10根取最小值，无数据设无穷大(不触发)
                            priceDistances.sort(by: >)
                            let top10Threshold = priceDistances.count >= 10
                                ? priceDistances[9]
                                : (priceDistances.last ?? Double.infinity)
                            var yMaxVol = 0
                            var yCumToNow = 0
                            for m in yData {
                                if m.minuteVol > yMaxVol { yMaxVol = m.minuteVol }
                                if let t = Int(m.time), t <= currentHHMM { yCumToNow = m.cumVol }
                            }
                            divergenceData = DivergenceData(
                                inWindow: true,
                                yesterdayMaxVol: yMaxVol,
                                yesterdayCumVolToNow: yCumToNow,
                                earlyVwapMax: earlyVMax,
                                todayMaxMinuteVol: todayMaxVol,
                                currentCumVol: curCumVol,
                                top10DistanceThreshold: top10Threshold
                            )
                        }

                        // 用计算好的指标重建StockData
                        let enrichedData = StockData(
                            name: data.name, code: data.code, price: data.price, prevClose: data.prevClose,
                            vwap: data.vwap, changePct: data.changePct, volume: data.volume, amount: data.amount,
                            volRatio: data.volRatio, open: data.open, high: data.high, low: data.low,
                            tradingPeriod: data.tradingPeriod, amplitude: data.amplitude,
                            upLimit: data.upLimit, downLimit: data.downLimit,
                            maxVwapDistance: maxVwapDistance, dayLowDistance: dayLowDistance,
                            minutesSinceHigh: minutesSinceHigh, minutesSinceVolHigh: minutesSinceVolHigh,
                            divergence: divergenceData
                        )

                        let analysis = VWAPAnalyzer.analyze(data: enrichedData, trend: trend)
                        self.signal = analysis.signal
                        self.pattern = analysis.pattern
                        self.patternReason = analysis.reason
                        self.patternConfidence = analysis.confidence
                        self.recommendation = analysis.recommendation
                        self.buySignal = analysis.buySignal
                        self.sellSignal = analysis.sellSignal

                        // 量价背离卖点持续15分钟逻辑
                        if analysis.divergenceSell {
                            self.divergenceTriggered = true
                            self.divergenceTriggerTime = Date()
                            Logger.shared.info("量价背离卖点触发，进入15分钟持续期")
                        } else if self.divergenceTriggered {
                            if let triggerTime = self.divergenceTriggerTime,
                               Date().timeIntervalSince(triggerTime) < 15 * 60 {
                                // 爆量拉升判断：近期量比>=2.0 且 均价斜率向上
                                if trend.volRatioRecent >= 2.0 && trend.slope > 0 {
                                    self.divergenceTriggered = false
                                    self.divergenceTriggerTime = nil
                                    Logger.shared.info("量价背离持续期内出现爆量拉升，解除卖出信号")
                                } else {
                                    self.sellSignal = true
                                    self.signal = "sell"
                                    self.recommendation = "sell"
                                    self.pattern = "量价背离卖点(持续)"
                                    self.patternReason = "量价背离触发后15分钟持续卖出"
                                    self.patternConfidence = 80
                                    Logger.shared.info("量价背离持续卖出中")
                                }
                            } else {
                                self.divergenceTriggered = false
                                self.divergenceTriggerTime = nil
                                Logger.shared.info("量价背离持续期结束(15分钟)")
                            }
                        }

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
