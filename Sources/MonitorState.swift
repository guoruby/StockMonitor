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
    @Published var marketTrend: String = "--"  // 沪深300大盘环境：多/空/平
    @Published var marketPressure: String = "" // 沪深300压力状态：承压/突破/弱
    @Published var priceLevelStatus: String = ""  // 压力支撑位状态：突破压力/跌破支撑/""
    @Published var sectorTop3: [SectorStrength] = []  // 短线侠板块强度前三名

    var config: AppConfig = AppConfig.load()
    private var timer: Timer?
    private var shakeTimer: Timer?
    private var shakeStep: Int = 0
    private var nameToCodeCache: [String: String] = [:]

    // 量价背离卖点策略状态
    private var minuteDataCache: [String: (today: [MinuteData], yesterday: [MinuteData])] = [:]
    private var minuteDataCacheTime: [String: Date] = [:]
    private var minuteFetchingCodes: Set<String> = []
    private var divergenceTriggered: Bool = false
    private var divergenceTriggerTime: Date?
    private var lastFetchCode: String = ""

    // 沪深300大盘环境数据
    private var hs300Cache: (today: [MinuteData], yesterday: [MinuteData], prec: Double, yVwap: Double, yChangePct: Double)?
    private var hs300CacheTime: Date?
    private var hs300Fetching: Bool = false

    // 短线侠板块强度
    private var sectorTimer: Timer?
    private var sectorCacheTime: Date?
    private var sectorFetching: Bool = false

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

        // 板块强度：盘中15秒刷新，盘后1分钟刷新
        let now = Date()
        let cal = Calendar.current
        let hhmm = cal.component(.hour, from: now) * 100 + cal.component(.minute, from: now)
        let inTrading = hhmm >= 930 && hhmm <= 1500
        let sectorInterval: TimeInterval = inTrading ? 15 : 60
        sectorTimer = Timer.scheduledTimer(withTimeInterval: sectorInterval, repeats: true) { [weak self] _ in
            self?.fetchSectorStrength()
        }
        fetchSectorStrength()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        sectorTimer?.invalidate()
        sectorTimer = nil
        stopShaking()
        statusMessage = "已停止"
        Logger.shared.info("停止监控")
    }

    private func fetchSectorStrength() {
        let now = Date()
        let cal = Calendar.current
        let hhmm = cal.component(.hour, from: now) * 100 + cal.component(.minute, from: now)
        let inTrading = hhmm >= 930 && hhmm <= 1500
        let cacheAge = sectorCacheTime.map { now.timeIntervalSince($0) } ?? Double.infinity
        let minInterval: TimeInterval = inTrading ? 15 : 60
        guard sectorCacheTime == nil || cacheAge >= minInterval else { return }
        guard !sectorFetching else { return }
        sectorFetching = true

        APIService.shared.fetchSectorStrength { [weak self] sectors in
            guard let self = self else { return }
            self.sectorFetching = false
            guard let sectors = sectors, !sectors.isEmpty else {
                Logger.shared.error("板块强度: 拉取失败或为空")
                return
            }
            self.sectorCacheTime = Date()
            let top3 = Array(sectors.prefix(3))
            DispatchQueue.main.async {
                self.sectorTop3 = top3
            }
        }
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

        // 异步获取5日分时数据：盘中20秒过期重新请求，盘后直接用缓存
        let now = Date()
        let cal = Calendar.current
        let hh = cal.component(.hour, from: now)
        let mm = cal.component(.minute, from: now)
        let hhmm = hh * 100 + mm
        let inTrading = hhmm >= 930 && hhmm <= 1500
        let cacheAge = minuteDataCacheTime[code].map { now.timeIntervalSince($0) } ?? Double.infinity
        let cacheExpired = inTrading && cacheAge >= 20
        let needFetch = minuteDataCache[code] == nil || cacheExpired
        if needFetch && !minuteFetchingCodes.contains(code) {
            minuteFetchingCodes.insert(code)
            APIService.shared.fetch5DayMinuteData(stockCode: code) { [weak self] result in
                guard let self = self else { return }
                if let result = result {
                    self.minuteDataCache[code] = result
                    self.minuteDataCacheTime[code] = Date()
                    Logger.shared.info("5日分时数据已缓存: \(code) 今天\(result.today.count)条 昨天\(result.yesterday.count)条")
                }
                self.minuteFetchingCodes.remove(code)
            }
        }

        // 请求实时行情（分时数据从5日接口缓存获取，避免当日分时接口被WAF拦截）
        APIService.shared.fetchRealtimeData(stockCode: code) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                DispatchQueue.main.async {
                    // 从5日分时缓存获取今日分时数据
                    let minuteData = self.minuteDataCache[code]?.today
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

                    if inWindow, let yData = self.minuteDataCache[code]?.yesterday {
                        var todayMaxVol = 0
                        var curCumVol = 0
                        var earlyVMax = 0.0
                        var priceDistances: [Double] = []
                        if let mData = minuteData {
                            for m in mData {
                                if let t = Int(m.time), t > currentHHMM { continue }
                                if m.minuteVol > todayMaxVol { todayMaxVol = m.minuteVol }
                                curCumVol = m.cumVol
                                if let t = Int(m.time), t >= 930 && t <= 939, m.cumVol > 0 {
                                    let v = m.cumAmt / (Double(m.cumVol) * 100.0)
                                    if v > earlyVMax { earlyVMax = v }
                                }
                                // 收集当前时刻及之前每根分钟线的偏离VWAP百分比（含正负，作为前5%基数）
                                if m.cumVol > 0 {
                                    let mVwap = m.cumAmt / (Double(m.cumVol) * 100.0)
                                    if mVwap > 0 {
                                        priceDistances.append((m.price - mVwap) / mVwap * 100)
                                    }
                                }
                            }
                        }
                        // Top10阈值：所有分钟线偏离(含负)按从大到小排序，取第10大值
                        // 当前偏离>=此值说明排进所有K线的前10，属于日内显著偏离
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
                            top10Threshold: top10Threshold
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

                    // 压力支撑位检查（作为买卖信号的一个维度叠加）
                    self.checkPriceLevels(data: data)

                    Logger.shared.info("信号: \(analysis.signal) 形态=\(analysis.pattern) 置信=\(analysis.confidence) 原因=\(analysis.reason)")
                }

            case .failure(let error):
                Logger.shared.error("API调用失败: \(error.localizedDescription)")
            }
        }

        // 沪深300大盘环境（VWAP零轴+斜率，20秒缓存，盘中刷新）
        fetchHS300MarketTrend()
    }

    // 压力支撑位检查（多维度叠加：个股+沪深300）
    private func checkPriceLevels(data: StockData) {
        priceLevelStatus = ""
        let price = data.price

        // 1. 检查个股压力支撑位
        if let stockLevel = PriceLevelStore.shared.getStockLevel(code: data.code) {
            if price > stockLevel.pressure {
                // 突破压力位 → 买入信号维度
                if !sellSignal {
                    buySignal = true
                    priceLevelStatus = "突破压力\(String(format: "%.2f", stockLevel.pressure))"
                    if signal == "neutral" {
                        signal = "strong"
                        recommendation = "buy"
                    }
                    Logger.shared.info("突破个股压力位: \(stockLevel.pressure)，当前价: \(price)")
                }
            } else if price < stockLevel.support {
                // 跌破支撑位 → 卖出信号维度
                sellSignal = true
                priceLevelStatus = "跌破支撑\(String(format: "%.2f", stockLevel.support))"
                if signal != "limit_up" {
                    signal = "sell"
                    recommendation = "sell"
                    buySignal = false
                }
                Logger.shared.info("跌破个股支撑位: \(stockLevel.support)，当前价: \(price)")
            }
        }

        // 2. 检查沪深300压力支撑位（大盘环境辅助）
        if let hs300Level = PriceLevelStore.shared.hs300Level, !hs300Level.isExpired() {
            if let hs300Data = hs300Cache {
                let hs300Price = hs300Data.today.last?.price ?? 0
                if hs300Price > 0 && hs300Price > hs300Level.pressure && priceLevelStatus.isEmpty {
                    priceLevelStatus = "大盘突破压力\(String(format: "%.0f", hs300Level.pressure))"
                    Logger.shared.info("沪深300突破压力位: \(hs300Level.pressure)，当前: \(hs300Price)")
                } else if hs300Price > 0 && hs300Price < hs300Level.support {
                    if !sellSignal {
                        sellSignal = true
                        priceLevelStatus = "大盘跌破支撑\(String(format: "%.0f", hs300Level.support))"
                        if signal != "limit_up" {
                            signal = "sell"
                            recommendation = "sell"
                            buySignal = false
                        }
                        Logger.shared.info("沪深300跌破支撑位: \(hs300Level.support)，当前: \(hs300Price)")
                    }
                }
            }
        }
    }

    private func fetchHS300MarketTrend() {
        let now = Date()
        let cal = Calendar.current
        let hh = cal.component(.hour, from: now)
        let mm = cal.component(.minute, from: now)
        let hhmm = hh * 100 + mm
        let inTrading = hhmm >= 930 && hhmm <= 1500
        let cacheAge = hs300CacheTime.map { now.timeIntervalSince($0) } ?? Double.infinity
        let needFetch = hs300Cache == nil || (inTrading && cacheAge >= 20)

        if needFetch && !hs300Fetching {
            hs300Fetching = true
            APIService.shared.fetch5DayMinuteData(stockCode: "sh000300") { [weak self] result in
                guard let self = self else { return }
                self.hs300Fetching = false
                guard let result = result, result.yesterday.count > 0 else { return }
                let prec = result.yesterday.last?.price ?? 0
                // 昨日VWAP：昨日全天累计额 / 累计量
                let yLast = result.yesterday.last!
                let yVwap = yLast.cumVol > 0 ? yLast.cumAmt / (Double(yLast.cumVol) * 100.0) : prec
                // 昨日涨跌幅：(昨日收盘 - 前日昨收) / 前日昨收 * 100
                let yChangePct = prec > 0 ? (yLast.price - prec) / prec * 100 : 0
                self.hs300Cache = (result.today, result.yesterday, prec, yVwap, yChangePct)
                self.hs300CacheTime = Date()
                self.updateMarketTrend()
            }
        } else if hs300Cache != nil {
            updateMarketTrend()
        }
    }

    private func updateMarketTrend() {
        guard let cache = hs300Cache, cache.today.count >= 2, cache.prec > 0 else {
            marketTrend = "--"
            marketPressure = ""
            return
        }

        // 1. 今日多空趋势（VWAP零轴+斜率）
        let trend = VWAPAnalyzer.calcTrendFromMinute(cache.today, prevClose: cache.prec)
        if trend.vwapVsZero > 0.5 && trend.slope > 0 {
            marketTrend = "多"
        } else if trend.vwapVsZero < -0.5 && trend.slope < 0 {
            marketTrend = "空"
        } else {
            marketTrend = "平"
        }

        // 2. 昨日压力判断
        // 昨日大跌(跌幅>1%) → 今日承压，看开盘5分钟能否突破昨日均价
        if cache.yChangePct < -1.0 && cache.yVwap > 0 {
            let cal = Calendar.current
            let now = Date()
            let hh = cal.component(.hour, from: now)
            let mm = cal.component(.minute, from: now)
            let hhmm = hh * 100 + mm

            // 取今日开盘5分钟(9:30-9:35)的数据
            let first5Min = cache.today.filter { m in
                if let t = Int(m.time), t >= 930 && t <= 935 { return true }
                return false
            }

            if first5Min.count >= 2 {
                // 开盘5分钟内最新均价和实时价格都站上昨日均价 → 突破压力
                let lastIn5 = first5Min.last!
                let curVwap = lastIn5.cumVol > 0 ? lastIn5.cumAmt / (Double(lastIn5.cumVol) * 100.0) : lastIn5.price
                if curVwap > cache.yVwap && lastIn5.price > cache.yVwap {
                    marketPressure = "突破"
                } else {
                    marketPressure = "弱"
                }
            } else if hhmm > 935 {
                // 已过9:35但5分钟数据不足，用当前数据判断
                let last = cache.today.last!
                let curVwap = last.cumVol > 0 ? last.cumAmt / (Double(last.cumVol) * 100.0) : last.price
                if curVwap > cache.yVwap && last.price > cache.yVwap {
                    marketPressure = "突破"
                } else {
                    marketPressure = "弱"
                }
            } else {
                // 9:35之前数据不足，暂不判断
                marketPressure = "承压"
            }
        } else {
            marketPressure = ""
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
