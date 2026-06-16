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

    // MARK: - 股票名称查代码

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
        let decoded = decodeUnicodeEscapes(content)

        let results = decoded.components(separatedBy: "^")
        for result in results {
            let parts = result.components(separatedBy: "~")
            guard parts.count >= 3 else { continue }

            let market = parts[0]
            let code = parts[1]

            if market == "sh" || market == "sz" {
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

    // MARK: - 实时行情

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
            let prevClose = Double(parts[safe: 4] ?? "") ?? 0
            let openPrice = Double(parts[safe: 5] ?? "") ?? 0
            let volume = (Int(parts[safe: 6] ?? "") ?? 0) * 100
            let changePct = Double(parts[safe: 32] ?? "") ?? 0
            let amount = (Double(parts[safe: 37] ?? "") ?? 0) * 10000
            let high = Double(parts[safe: 41] ?? "") ?? price
            let low = Double(parts[safe: 42] ?? "") ?? price
            let amplitude = Double(parts[safe: 43] ?? "") ?? 0
            let volRatio = Double(parts[safe: 49] ?? "") ?? 1.0

            let vwap = volume > 0 ? amount / Double(volume) : price

            // 根据股票代码计算涨跌停价
            let limitRatio = Self.getLimitRatio(stockCode: stockCode, stockName: name)
            let upLimit = prevClose > 0 ? (prevClose * (1 + limitRatio) * 100).rounded() / 100 : 0
            let downLimit = prevClose > 0 ? (prevClose * (1 - limitRatio) * 100).rounded() / 100 : 0

            Logger.shared.info("API解析: \(name)(\(stockCode)) 价=\(String(format:"%.2f",price)) 昨收=\(prevClose) 涨跌幅=\(changePct)% 振幅=\(amplitude) 量比=\(volRatio)")

            let tradingPeriod = Self.getTradingPeriod()

            let stockData = StockData(
                name: name, code: stockCode, price: price, prevClose: prevClose,
                vwap: vwap, changePct: changePct, volume: volume, amount: amount,
                volRatio: volRatio, open: openPrice, high: high, low: low,
                tradingPeriod: tradingPeriod, amplitude: amplitude,
                upLimit: upLimit, downLimit: downLimit,
                maxVwapDistance: 0, dayLowDistance: 0, minutesSinceHigh: 0, minutesSinceVolHigh: 0
            )
            completion(.success(stockData))
        }.resume()
    }

    // MARK: - 分时数据

    func fetchMinuteData(stockCode: String, completion: @escaping ([MinuteData]?) -> Void) {
        let tencentCode: String
        if stockCode.hasPrefix("6") {
            tencentCode = "sh\(stockCode)"
        } else if stockCode.hasPrefix("0") || stockCode.hasPrefix("3") {
            tencentCode = "sz\(stockCode)"
        } else {
            tencentCode = stockCode
        }

        let urlStr = "https://web.ifzq.gtimg.cn/appstock/app/minute/query?_var=min_data&code=\(tencentCode)"
        guard let url = URL(string: urlStr) else {
            completion(nil)
            return
        }

        session.dataTask(with: url) { data, _, error in
            if error != nil || data == nil {
                completion(nil)
                return
            }

            guard let text = String(data: data!, encoding: .utf8) else {
                completion(nil)
                return
            }

            // 解析: "0930 1272.00 600 76320000.00"
            let pattern = "(\\d{4})\\s+([\\d.]+)\\s+(\\d+)\\s+([\\d.]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                completion(nil)
                return
            }

            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            var result: [MinuteData] = []
            var prevCumVol = 0

            for match in matches {
                guard match.numberOfRanges == 5 else { continue }
                let timeStr = String(text[Range(match.range(at: 1), in: text)!])
                let price = Double(String(text[Range(match.range(at: 2), in: text)!])) ?? 0
                let cumVol = Int(String(text[Range(match.range(at: 3), in: text)!])) ?? 0
                let cumAmt = Double(String(text[Range(match.range(at: 4), in: text)!])) ?? 0
                let minuteVol = cumVol - prevCumVol
                prevCumVol = cumVol

                result.append(MinuteData(time: timeStr, price: price, cumVol: cumVol, cumAmt: cumAmt, minuteVol: minuteVol))
            }

            Logger.shared.info("分时数据: \(stockCode) 共\(result.count)条")
            completion(result.count > 0 ? result : nil)
        }.resume()
    }

    // MARK: - 涨跌幅限制比例

    private static func getLimitRatio(stockCode: String, stockName: String) -> Double {
        // ST/*ST: 5%
        if stockName.contains("*ST") || stockName.contains("ST") { return 0.05 }
        // 创业板(300/301): 20%
        if stockCode.hasPrefix("300") || stockCode.hasPrefix("301") { return 0.20 }
        // 科创板(688/689): 20%
        if stockCode.hasPrefix("688") || stockCode.hasPrefix("689") { return 0.20 }
        // 北交所(83/87): 30%
        if stockCode.hasPrefix("83") || stockCode.hasPrefix("87") { return 0.30 }
        // 主板/中小板: 10%
        return 0.10
    }

    // MARK: - 交易时段

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
