import Foundation

class VWAPAnalyzer {
    static func analyze(data: StockData) -> VWAPAnalysis {
        let price = data.price
        let vwap = data.vwap
        let volRatio = data.volRatio
        let changePct = data.changePct
        let flowStrength = data.flowStrength
        let pressureRatio = data.pressureRatio
        let period = data.tradingPeriod

        let vwapDistance = vwap > 0 ? (price - vwap) / vwap * 100 : 0
        let priceAboveVWAP = price > vwap

        var baseAdjust = 0
        var moneySignal = 0

        if flowStrength > 5 && priceAboveVWAP {
            baseAdjust += 10
            moneySignal = 1
        } else if flowStrength < -5 && !priceAboveVWAP {
            baseAdjust -= 10
            moneySignal = -1
        }
        if pressureRatio > 1.2 {
            baseAdjust += 5
        } else if pressureRatio < 0.8 {
            baseAdjust -= 5
        }

        let volumeStatus: String
        if volRatio > 1.5 { volumeStatus = "放量" }
        else if volRatio < 0.7 { volumeStatus = "缩量" }
        else { volumeStatus = "平量" }

        var pattern = "normal"
        var buySignal = false
        var sellSignal = false
        var confidence = 50
        var reason = ""

        if priceAboveVWAP && vwapDistance > 0.5 && volRatio > 1.2 {
            pattern = "放量突破"
            buySignal = true
            confidence = min(95, 70 + Int(volRatio * 10))
            confidence = min(100, confidence + baseAdjust)
            reason = "放量突破均价线+\(String(format: "%.1f", vwapDistance))%，量比\(String(format: "%.1f", volRatio))"
        } else if !priceAboveVWAP && vwapDistance > -1 && volRatio < 0.8 {
            if abs(price - vwap) < price * 0.02 {
                pattern = "缩量回踩"
                buySignal = true
                confidence = min(90, 65 + Int((1 - volRatio) * 30))
                confidence = min(100, confidence + baseAdjust)
                reason = "缩量回踩均价线(\(String(format: "%.1f", volRatio))x)，主力控盘"
            }
        } else if period == "开盘初期" && changePct > 0 && volRatio < 0.6 {
            if data.low > 0 && price > data.open * 1.005 {
                pattern = "开盘缩量探底回升"
                buySignal = true
                confidence = min(100, 80 + baseAdjust)
                reason = "开盘缩量震荡后放量拉升，主力控盘明显"
            }
        } else if period == "尾盘" && changePct > 2 && volRatio > 1.5 {
            pattern = "尾盘放量"
            buySignal = true
            confidence = min(100, 75 + baseAdjust)
            reason = "尾盘放量拉升(\(String(format: "%.1f", volRatio))x)，明日有惯性"
        }

        if buySignal && flowStrength > 10 && volRatio > 1.5 {
            confidence = min(100, confidence + 8)
            reason += "，主力净买入\(String(format: "%.1f", flowStrength))%"
        }

        if changePct > 3 && volRatio < 0.6 && vwapDistance > 3 {
            pattern = "量价背离"
            sellSignal = true
            confidence = min(100, 85 + abs(baseAdjust))
            reason = "缩量上涨(\(String(format: "%.1f", volRatio))x)远离均价\(String(format: "%.1f", vwapDistance))%，背离信号"
        } else if !priceAboveVWAP && vwapDistance < -2 && volRatio > 1.5 {
            pattern = "放量破位"
            sellSignal = true
            confidence = min(100, 80 + abs(baseAdjust))
            reason = "放量跌破均价线，量比\(String(format: "%.1f", volRatio))，下跌信号"
        } else if changePct > 7 && volRatio < 0.5 {
            pattern = "高位滞涨"
            sellSignal = true
            confidence = min(100, 75 + abs(baseAdjust))
            reason = "涨幅\(String(format: "%.1f", changePct))%但量比仅\(String(format: "%.1f", volRatio))，滞涨信号"
        }

        if sellSignal && flowStrength < -10 {
            confidence = min(100, confidence + 8)
            reason += "，主力净卖出\(String(format: "%.1f", abs(flowStrength)))%"
        }

        var signal: String
        var recommendation: String

        if sellSignal {
            if pattern == "高位滞涨" || pattern == "放量破位" {
                signal = "sell"
                recommendation = "sell"
            } else {
                signal = "weak"
                recommendation = "hold"
            }
        } else if buySignal && confidence >= 70 {
            signal = "strong"
            recommendation = "buy"
        } else if priceAboveVWAP && vwapDistance > 1 {
            signal = "strong"
            recommendation = "buy"
        } else if !priceAboveVWAP && vwapDistance < -1 {
            signal = "weak"
            recommendation = "avoid"
        } else {
            signal = "neutral"
            recommendation = "hold"
        }

        return VWAPAnalysis(
            signal: signal, recommendation: recommendation,
            pattern: pattern, reason: reason,
            confidence: confidence, volumeStatus: volumeStatus,
            moneySignal: moneySignal
        )
    }
}
