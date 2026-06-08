import Foundation

class VWAPAnalyzer {

    // MARK: - 线性回归斜率

    private static func linreg(_ vals: [Double]) -> Double {
        let n = vals.count
        if n < 2 { return 0.0 }
        let xMean = Double(n - 1) / 2.0
        let xSqSum = (0..<n).reduce(0.0) { $0 + pow(Double($1) - xMean, 2) }
        if xSqSum == 0 { return 0.0 }
        let yMean = vals.reduce(0, +) / Double(n)
        return (0..<n).reduce(0.0) { $0 + (Double($1) - xMean) * (vals[$1] - yMean) } / xSqSum
    }

    // MARK: - 从分时数据计算趋势指标

    static func calcTrendFromMinute(_ minuteData: [MinuteData], prevClose: Double, window: Int = 10) -> TrendIndicators {
        if minuteData.count < 2 {
            return TrendIndicators(vwap: 0, vwapVsZero: 0, slope: 0, acceleration: 0,
                                   vwapTrend: "unknown", recentAvgVol: 0, overallAvgVol: 0, volRatioRecent: 1.0)
        }

        // 每分钟均价序列
        var vwapSeries: [Double] = []
        for d in minuteData {
            let avg = d.cumVol > 0 ? d.cumAmt / Double(d.cumVol) : d.price
            vwapSeries.append(avg)
        }

        let currentVwap = vwapSeries.last!
        let vwapVsZero = prevClose > 0 ? (currentVwap - prevClose) / prevClose * 100 : 0

        // 趋势方向（首尾比较）
        let vwapTrend: String
        if vwapSeries.count >= 2 {
            let first = vwapSeries.first!
            let last = vwapSeries.last!
            if first > 0 {
                let changePct = (last - first) / first * 100
                vwapTrend = changePct > 0.1 ? "up" : changePct < -0.1 ? "down" : "flat"
            } else {
                vwapTrend = "unknown"
            }
        } else {
            vwapTrend = "unknown"
        }

        // 斜率（最近window根线性回归）
        let slope: Double
        if vwapSeries.count >= window {
            slope = linreg(Array(vwapSeries.suffix(window)))
        } else if vwapSeries.count >= 2 {
            slope = linreg(vwapSeries)
        } else {
            slope = 0.0
        }

        // 加速度
        let acceleration: Double
        if vwapSeries.count >= window * 2 {
            let slopeRecent = linreg(Array(vwapSeries.suffix(window)))
            let slopeEarlier = linreg(Array(vwapSeries.suffix(window * 2).prefix(window)))
            acceleration = slopeRecent - slopeEarlier
        } else {
            acceleration = 0.0
        }

        // 量能指标
        let vols = minuteData.map { Double(max($0.minuteVol, 0)) }
        let overallAvgVol = vols.reduce(0.0, +) / Double(vols.count)
        let recentVols = vols.suffix(min(window, vols.count))
        let recentAvgVol = recentVols.reduce(0.0, +) / Double(recentVols.count)
        let volRatioRecent: Double = overallAvgVol > 0 ? recentAvgVol / overallAvgVol : 1.0

        return TrendIndicators(
            vwap: currentVwap, vwapVsZero: vwapVsZero, slope: slope, acceleration: acceleration,
            vwapTrend: vwapTrend, recentAvgVol: recentAvgVol, overallAvgVol: overallAvgVol,
            volRatioRecent: volRatioRecent
        )
    }

    // MARK: - 量价形态分析（ComeMoney v6.0 逻辑）

    static func analyze(data: StockData, trend: TrendIndicators) -> VWAPAnalysis {
        let price = data.price
        let vwap = trend.vwap > 0 ? trend.vwap : data.vwap
        let prevClose = data.prevClose
        let period = data.tradingPeriod

        let vwapDistance = vwap > 0 ? (price - vwap) / vwap * 100 : 0
        let priceAboveVwap = price > vwap

        let vwapVsZero = trend.vwapVsZero
        let slope = trend.slope
        let acceleration = trend.acceleration
        let volRatioRecent = trend.volRatioRecent

        // ── 量能状态 ──
        let volumeStatus: String
        if volRatioRecent > 2.0 { volumeStatus = "急放" }
        else if volRatioRecent > 1.5 { volumeStatus = "放量" }
        else if volRatioRecent >= 0.8 { volumeStatus = "平量" }
        else if volRatioRecent >= 0.5 { volumeStatus = "缩量" }
        else { volumeStatus = "地量" }

        // ── 零轴位置 ──
        let vwapAboveZero = vwapVsZero > 0.5

        // ── 斜率方向 ──
        let slopeThreshold = prevClose > 0 ? prevClose * 0.0003 : 0.003
        let slopeDir: String
        if slope > slopeThreshold { slopeDir = "up" }
        else if slope < -slopeThreshold { slopeDir = "down" }
        else { slopeDir = "flat" }

        // ── 加速度方向 ──
        let accThreshold = prevClose > 0 ? prevClose * 0.0001 : 0.001
        let accPositive = acceleration > accThreshold
        let accNegative = acceleration < -accThreshold

        // ── 硬过滤：VWAP在零轴下方<-1%禁止买入 ──
        let buyBlocked = vwapVsZero < -1.0

        var pattern = "normal"
        var buySignal = false
        var sellSignal = false
        var confidence = 50
        var reason = ""

        // ═══════════════════════════════════════
        // 买入信号（按优先级，首个匹配即止）
        // ═══════════════════════════════════════

        if !buyBlocked {
            // 1. 放量回升（最强买入）
            // 均线下方 + 斜率拐头(平/上) + 加速度>0 + 放量(>1.5)
            if !priceAboveVwap && (slopeDir == "flat" || slopeDir == "up") && accPositive && volRatioRecent > 1.5 {
                pattern = "放量回升"
                buySignal = true
                var conf = 85
                if vwapAboveZero { conf += 10 }
                if vwapDistance < -3 { conf += 5 }
                confidence = min(95, conf)
                reason = "均线下方放量回升+斜率拐头+零轴\(vwapAboveZero ? "上方" : "附近")+\(volumeStatus)，最强反转信号"
            }
            // 2. 缩量企稳（经典买入）
            // 均线下方 + 斜率弱(下/平) + 加速度>0 + 缩量(<0.8)
            else if !priceAboveVwap && (slopeDir == "down" || slopeDir == "flat") && accPositive && volRatioRecent < 0.8 {
                pattern = "缩量企稳"
                buySignal = true
                var conf = 70
                if vwapAboveZero { conf += 10 }
                if vwapDistance < -3 { conf += 10 }
                if volRatioRecent < 0.5 { conf += 10 }
                confidence = min(95, conf)
                reason = "均线下方缩量企稳+卖压枯竭+偏离\(String(format: "%.1f", vwapDistance))%+\(volumeStatus)，经典买点"
            }
            // 3. 突破启动
            // 均线上方 + 斜率拐头(平/上) + 加速度>0 + 偏离<3%
            else if priceAboveVwap && (slopeDir == "flat" || slopeDir == "up") && accPositive && vwapDistance < 3 {
                pattern = "突破启动"
                buySignal = true
                var conf = 65
                if vwapAboveZero { conf += 10 }
                if volRatioRecent > 1.5 { conf += 5 }
                confidence = min(80, conf)
                reason = "均线上方突破启动+斜率拐头+零轴\(vwapAboveZero ? "上方" : "附近")，趋势启动信号"
            }
            // 4. 加速上涨
            // 斜率向上 + 加速度>0 + 偏离<3%
            else if slopeDir == "up" && accPositive && vwapDistance < 3 {
                pattern = "加速上涨"
                buySignal = true
                var conf = 55
                if volRatioRecent > 1.5 { conf += 5 }
                if volRatioRecent < 0.8 { conf -= 10 }
                if vwapDistance > 2 { conf -= 10 }
                confidence = min(75, conf)
                reason = "加速上涨+趋势延续+偏离\(String(format: "%+.1f", vwapDistance))%+\(volumeStatus)"
            }
            // 5. 横盘地量见底
            // 斜率横盘 + 零轴上方 + 均线下方 + 地量(<0.6)
            else if slopeDir == "flat" && vwapAboveZero && !priceAboveVwap && volRatioRecent < 0.6 {
                pattern = "横盘地量见底"
                buySignal = true
                var conf = 65
                if vwapAboveZero { conf += 5 }
                confidence = min(70, conf)
                reason = "横盘地量见底+零轴上方+\(volumeStatus)，底部信号"
            }
        }

        // ── 零轴下方弱势（无买入信号时） ──
        if buyBlocked && !buySignal {
            pattern = "零轴下方弱势"
            confidence = 20
            reason = "VWAP在昨收下方\(String(format: "%.1f", vwapVsZero))%，弱势不参与"
        }

        // ═══════════════════════════════════════
        // 卖出信号判定
        // ═══════════════════════════════════════

        // 快速拉升判定：斜率上行+加速度为正=正在加速上涨，此时偏离均线是正常的
        let isSurging = slopeDir == "up" && accPositive

        // 1. 放量滞涨（最危险）
        if priceAboveVwap && vwapDistance > 2 && volRatioRecent > 1.5 && (slopeDir == "down" || accNegative) && !isSurging {
            pattern = "放量滞涨"
            sellSignal = true
            var conf = 80
            if slopeDir == "down" { conf += 10 }
            confidence = min(90, conf)
            reason = "放量滞涨+偏离\(String(format: "%.1f", vwapDistance))%+\(volumeStatus)+趋势走弱，全仓离场"
        }
        // 2. 缩量上涨背离
        else if priceAboveVwap && vwapDistance > 3 && volRatioRecent < 0.6 && !isSurging {
            pattern = "缩量上涨背离"
            sellSignal = true
            var conf = 75
            if vwapDistance > 5 { conf += 10 }
            confidence = min(85, conf)
            reason = "缩量上涨背离+偏离\(String(format: "%.1f", vwapDistance))%+\(volumeStatus)，减仓"
        }
        // 3. 均线上方偏离
        else if priceAboveVwap && vwapDistance > 3 && volRatioRecent >= 0.6 && !isSurging {
            pattern = "均线上方偏离"
            sellSignal = true
            var conf: Int
            if slopeDir == "up" && !accNegative {
                conf = 60
                reason = "均线上方偏离\(String(format: "%.1f", vwapDistance))%+趋势延续，减仓50%"
            } else {
                conf = 70
                reason = "均线上方偏离\(String(format: "%.1f", vwapDistance))%+趋势走弱，减仓70%"
            }
            conf += min(15, Int((vwapDistance - 3) * 3))
            confidence = min(85, conf)
        }

        // 4. 放量破位
        if !priceAboveVwap && vwapDistance < -3 && volRatioRecent > 1.5 {
            pattern = "放量破位"
            sellSignal = true
            confidence = 85
            reason = "放量破位+偏离\(String(format: "%.1f", vwapDistance))%+\(volumeStatus)，全仓离场"
        }
        // 5. 尾盘放量破位
        else if period == "尾盘" && !priceAboveVwap && volRatioRecent > 2 {
            pattern = "尾盘放量破位"
            sellSignal = true
            confidence = 75
            reason = "尾盘放量破均线，明日可能继续跌"
        }

        // 买卖互斥：卖出优先
        if buySignal && sellSignal {
            buySignal = false
        }

        // ═══════════════════════════════════════
        // 最终信号映射
        // ═══════════════════════════════════════

        let isLimitUp = data.upLimit > 0 && price >= data.upLimit * 0.998
        let isLimitDown = data.downLimit > 0 && price <= data.downLimit * 1.002

        let signal: String
        let recommendation: String

        if isLimitUp {
            signal = "limit_up"
            recommendation = "avoid"
        } else if isLimitDown {
            signal = "limit_down"
            recommendation = "avoid"
        } else if sellSignal {
            signal = "sell"
            recommendation = "sell"
        } else if buySignal && confidence >= 50 {
            signal = "strong"
            recommendation = "buy"
        } else if !priceAboveVwap && vwapDistance < -1 {
            signal = "strong"
            recommendation = "buy"
        } else if priceAboveVwap && vwapDistance > 1 {
            signal = "weak"
            recommendation = "sell"
        } else {
            signal = "neutral"
            recommendation = "hold"
        }

        return VWAPAnalysis(
            signal: signal, recommendation: recommendation,
            pattern: pattern, reason: reason,
            confidence: confidence, volumeStatus: volumeStatus,
            buySignal: buySignal, sellSignal: sellSignal
        )
    }
}
