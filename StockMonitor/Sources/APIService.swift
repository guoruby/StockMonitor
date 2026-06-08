import Foundation
import CoreFoundation

class APIService {
    static let shared = APIService()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        self.session = URLSession(configuration: config)
    }

    func searchStockCode(name: String, completion: @escaping (String?) -> Void) {
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://smartbox.gtimg.cn/s3/?q=\(encoded)&t=all") else {
            Logger.shared.error("股票名称查询: URL构建失败 name=\(name)")
            completion(nil)
            return
        }

        Logger.shared.info("股票名称查询: \(name)")

        session.dataTask(with: url) { data, _, error in
            if let error = error {
                Logger.shared.error("股票名称查询网络错误: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let data = data else {
                Logger.shared.error("股票名称查询: 无响应数据")
                completion(nil)
                return
            }

            let gbEncoding = CFStringConvertEncodingToNSStringEncoding(0x0631)
            let gb18030 = String.Encoding(rawValue: gbEncoding)
            let text = String(data: data, encoding: gb18030)
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            let code = Self.parseSmartboxResult(text, searchName: name)
            if let code = code {
                Logger.shared.info("股票名称查询成功: \(name) -> \(code)")
            } else {
                Logger.shared.error("股票名称查询失败: \(name), 响应=\(String(text.prefix(200)))")
            }
            completion(code)
        }.resume()
    }

    private static func parseSmartboxResult(_ text: String, searchName: String) -> String? {
        guard text.contains("v_hint=\"") else {
            Logger.shared.error("parseSmartbox: 不包含v_hint")
            return nil
        }

        guard let hintRange = text.range(of: "v_hint=\"") else {
            Logger.shared.error("parseSmartbox: range查找失败")
            return nil
        }
        let start = hintRange.upperBound
        guard let end = text.range(of: "\"", range: start..<text.endIndex) else {
            Logger.shared.error("parseSmartbox: 结尾引号查找失败")
            return nil
        }

        let content = String(text[start..<end.lowerBound])
        Logger.shared.info("parseSmartbox: 提取内容='\(content)'")

        let decoded = decodeUnicodeEscapes(content)
        Logger.shared.info("parseSmartbox: 解码后='\(decoded)'")

        let results = decoded.components(separatedBy: "^")
        Logger.shared.info("parseSmartbox: 结果数=\(results.count)")

        for (idx, result) in results.enumerated() {
            let parts = result.components(separatedBy: "~")
            Logger.shared.info("parseSmartbox: 结果[\(idx)] parts=\(parts)")
            guard parts.count >= 3 else { continue }

            let market = parts[0]
            let code = parts[1]
            let name = parts[2]

            if (market == "sh" || market == "sz") {
                return code
            }
        }

        Logger.shared.error("parseSmartbox: 没有找到A股结果")
        return nil
    }

    private static func decodeUnicodeEscapes(_ string: String) -> String {
        var result = string
        let pattern = "\\\\u([0-9a-fA-F]{4})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let hexStr = String(result[Range(match.range(at: 1), in: result)!])
            if let codePoint = UInt32(hexStr, radix: 16),
               let scalar = Unicode.Scalar(codePoint) {
                let replacement = String(scalar)
                result.replaceSubrange(Range(match.range, in: result)!, with: replacement)
            } else {
                break
            }
        }
        return result
    }

    func fetchRealtimeData(stockCode: String, completion: @escaping (Result<StockData, Error>) -> Void) {
        let tencentCode: String
        if stockCode.hasPrefix("6") {
            tencentCode = "sh\(stockCode)"
        } else if stockCode.hasPrefix("0") || stockCode.hasPrefix("3") {
            tencentCode = "sz\(stockCode)"
        } else {
            tencentCode = stockCode
        }

        let urlStr = "https://qt.gtimg.cn/q=\(tencentCode)"
        Logger.shared.info("API请求: \(urlStr)")

        guard let url = URL(string: urlStr) else {
            Logger.shared.error("API: URL无效")
            completion(.failure(NSError(domain: "APIService", code: -1)))
            return
        }

        session.dataTask(with: url) { data, response, error in
            if let error = error {
                Logger.shared.error("API网络错误: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }
            guard let data = data else {
                Logger.shared.error("API: 无响应数据")
                completion(.failure(NSError(domain: "APIService", code: -2)))
                return
            }

            let gbEncoding = CFStringConvertEncodingToNSStringEncoding(0x0631)
            let gb18030 = String.Encoding(rawValue: gbEncoding)
            let text = String(data: data, encoding: gb18030)
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""

            guard text.contains("~") else {
                Logger.shared.error("API: 响应数据无效, 前100字符: \(String(text.prefix(100)))")
                completion(.failure(NSError(domain: "APIService", code: -2)))
                return
            }

            let parts = text.components(separatedBy: "~")
            Logger.shared.info("API响应: 共\(parts.count)个字段")

            let priceStr = parts[safe: 3] ?? ""
            guard parts.count > 50, let price = Double(priceStr), price > 0 else {
                Logger.shared.error("API解析失败: count=\(parts.count) price=\(priceStr)")
                completion(.failure(NSError(domain: "APIService", code: -3)))
                return
            }

            let name = parts[safe: 1] ?? stockCode
            let openPrice = Double(parts[safe: 5] ?? "") ?? 0
            let volume = (Int(parts[safe: 6] ?? "") ?? 0) * 100
            let buyVolume = (Int(parts[safe: 7] ?? "") ?? 0) * 100
            let sellVolume = (Int(parts[safe: 8] ?? "") ?? 0) * 100
            let changePct = Double(parts[safe: 32] ?? "") ?? 0
            let high = Double(parts[safe: 33] ?? "") ?? price
            let low = Double(parts[safe: 34] ?? "") ?? price

            let amount = (Double(parts[safe: 37] ?? "") ?? 0) * 10000

            let rawAmplitude = parts[safe: 43] ?? ""
            let rawVolRatio = parts[safe: 49] ?? ""
            let amplitude = Double(rawAmplitude) ?? 0
            let volRatio = Double(rawVolRatio) ?? 1.0

            Logger.shared.info("API解析: \(name)(\(stockCode)) 价=\(String(format:"%.2f",price)) 涨跌幅=\(changePct)% 振幅=\(rawAmplitude)->\(amplitude) 量比=\(rawVolRatio)->\(volRatio)")

            let vwap = volume > 0 ? amount / Double(volume) : price
            let netFlow = buyVolume - sellVolume
            let flowStrength = volume > 0 ? Double(netFlow) / Double(volume) * 100 : 0

            var buyPressure = 0
            for i in [9, 11, 13, 15, 17] {
                buyPressure += Int(parts[safe: i] ?? "") ?? 0
            }
            var sellPressure = 0
            for i in [19, 21, 23, 25, 27] {
                sellPressure += Int(parts[safe: i] ?? "") ?? 0
            }
            let pressureRatio = sellPressure > 0 ? Double(buyPressure) / Double(sellPressure) : 1.0

            let tradingPeriod = Self.getTradingPeriod()

            let stockData = StockData(
                name: name, code: stockCode, price: price, vwap: vwap,
                changePct: changePct, volume: volume, amount: amount,
                volRatio: volRatio, flowStrength: flowStrength,
                buyPressure: buyPressure, sellPressure: sellPressure,
                pressureRatio: pressureRatio,
                open: openPrice, high: high, low: low,
                tradingPeriod: tradingPeriod,
                amplitude: amplitude
            )
            completion(.success(stockData))
        }.resume()
    }

    private static func getTradingPeriod() -> String {
        let now = Calendar.current.dateComponents([.hour, .minute, .weekday], from: Date())
        guard let hour = now.hour, let minute = now.minute, let weekday = now.weekday, weekday <= 5 else {
            return "非交易时段"
        }
        let t = hour * 60 + minute
        if t >= 570 && t <= 630 { return "开盘初期" }
        if t > 630 && t <= 690 { return "早盘尾段" }
        if t >= 780 && t <= 870 { return "午盘" }
        if t > 870 && t <= 900 { return "尾盘" }
        return "非交易时段"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
