import Foundation
import CoreFoundation
import CommonCrypto

// MARK: - 板块强度数据
struct SectorStrength {
    let name: String   // 板块名
    let strength: Int  // 强度值
    let limitUp: Int   // 涨停数
}

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
                maxVwapDistance: 0, dayLowDistance: 0, minutesSinceHigh: 0, minutesSinceVolHigh: 0,
                divergence: nil
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

    // MARK: - 5日分时数据（含今天和昨天，替代被WAF拦截的当日分时接口）

    func fetch5DayMinuteData(stockCode: String, completion: @escaping ((today: [MinuteData], yesterday: [MinuteData])?) -> Void) {
        let tencentCode: String
        if stockCode.hasPrefix("6") {
            tencentCode = "sh\(stockCode)"
        } else if stockCode.hasPrefix("0") || stockCode.hasPrefix("3") {
            tencentCode = "sz\(stockCode)"
        } else {
            tencentCode = stockCode
        }

        let urlStr = "https://web.ifzq.gtimg.cn/appstock/app/day/query?code=\(tencentCode)&args=2"
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

            // 解析JSON: data.{tencentCode}.data 是数组，每个元素含 date + data(字符串数组)
            guard let jsonData = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let dataDict = json["data"] as? [String: Any],
                  let stockDict = dataDict[tencentCode] as? [String: Any],
                  let dayDataArray = stockDict["data"] as? [[String: Any]] else {
                Logger.shared.error("5日分时JSON解析失败: \(stockCode)")
                completion(nil)
                return
            }

            guard dayDataArray.count >= 2 else {
                Logger.shared.info("5日分时数据不足: \(stockCode) 仅\(dayDataArray.count)天")
                completion(nil)
                return
            }

            let pattern = "(\\d{4})\\s+([\\d.]+)\\s+(\\d+)\\s+([\\d.]+)"
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                completion(nil)
                return
            }

            // 解析指定天的分时数据
            func parseDay(_ dayIdx: Int) -> [MinuteData] {
                guard let minuteStrings = dayDataArray[dayIdx]["data"] as? [String] else { return [] }
                var result: [MinuteData] = []
                var prevCumVol = 0
                for str in minuteStrings {
                    let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
                    for match in matches {
                        guard match.numberOfRanges == 5 else { continue }
                        let timeStr = String(str[Range(match.range(at: 1), in: str)!])
                        let price = Double(String(str[Range(match.range(at: 2), in: str)!])) ?? 0
                        let cumVol = Int(String(str[Range(match.range(at: 3), in: str)!])) ?? 0
                        let cumAmt = Double(String(str[Range(match.range(at: 4), in: str)!])) ?? 0
                        let minuteVol = cumVol - prevCumVol
                        prevCumVol = cumVol
                        result.append(MinuteData(time: timeStr, price: price, cumVol: cumVol, cumAmt: cumAmt, minuteVol: minuteVol))
                    }
                }
                return result
            }

            // dayDataArray[0]=今天, [1]=昨天
            let today = parseDay(0)
            let yesterday = parseDay(1)

            Logger.shared.info("5日分时数据: \(stockCode) 今天\(today.count)条 昨天\(yesterday.count)条")
            completion(today.count > 0 ? (today, yesterday) : nil)
        }.resume()
    }

    // MARK: - 板块强度（短线侠，AES-256-CBC解密）

    /// 短线侠板块强度接口（板强+主力流入两个tab）
    private enum SectorStrengthType {
        case strength   // 板块强度 val=强度值
        case moneyIn    // 主力流入 val=流入万元
    }

    // 短线侠AES-256-CBC密钥（从crypto.js逆向）
    private static let sectorKeyHex = "7365637265746b65793332327965732121616161616161616161616161616161"  // secretkey32yes!!aaaa...
    private static let sectorIVHex  = "666978656469765f313676616c756564"                                  // fixediv_16valued

    func fetchSectorStrength(completion: @escaping ([SectorStrength]?) -> Void) {
        fetchSectorStrengthImpl(type: .strength, completion: completion)
    }

    func fetchSectorMoneyIn(completion: @escaping ([SectorStrength]?) -> Void) {
        fetchSectorStrengthImpl(type: .moneyIn, completion: completion)
    }

    private func fetchSectorStrengthImpl(type: SectorStrengthType, completion: @escaping ([SectorStrength]?) -> Void) {
        let fileName = type == .strength ? "platechart1.json" : "platechart2.json"
        let urlStr = "https://www.duanxianxia.com/vendor/stockdata/\(fileName)"
        guard let url = URL(string: urlStr) else {
            Logger.shared.error("板块强度: URL无效")
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("https://www.duanxianxia.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        Logger.shared.info("板块强度请求: \(urlStr)")

        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error {
                Logger.shared.error("板块强度网络错误: \(error.localizedDescription)")
                completion(nil)
                return
            }
            guard let data = data, let cipherText = String(data: data, encoding: .utf8) else {
                Logger.shared.error("板块强度: 无响应数据")
                completion(nil)
                return
            }

            guard let plainText = self.decryptAES256CBC(base64Cipher: cipherText) else {
                Logger.shared.error("板块强度: 解密失败, 密文前50=\(String(cipherText.prefix(50)))")
                completion(nil)
                return
            }

            guard let jsonData = plainText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let plates = json["plates"] as? [String: Any] else {
                Logger.shared.error("板块强度: JSON解析失败")
                completion(nil)
                return
            }

            var result: [SectorStrength] = []
            for (_, val) in plates {
                guard let dict = val as? [String: Any],
                      let name = dict["name"] as? String,
                      let strengthStr = dict["val"] as? String,
                      let limitUpStr = dict["ztcount"] as? String else { continue }
                let strength = Int(strengthStr) ?? 0
                let limitUp = Int(limitUpStr) ?? 0
                result.append(SectorStrength(name: name, strength: strength, limitUp: limitUp))
            }

            // 按强度/主力流入降序
            result.sort { $0.strength > $1.strength }

            Logger.shared.info("板块强度解析成功: 共\(result.count)条, Top3=\(result.prefix(3).map { "\($0.name)(\($0.strength))/\($0.limitUp)涨停" }.joined(separator: ", "))")
            completion(result)
        }.resume()
    }

    /// AES-256-CBC + PKCS7 + Base64 解密
    private func decryptAES256CBC(base64Cipher: String) -> String? {
        guard let keyData = Self.hexToData(Self.sectorKeyHex),
              let ivData = Self.hexToData(Self.sectorIVHex),
              let cipherData = Data(base64Encoded: base64Cipher) else {
            return nil
        }

        let bufferSize = cipherData.count + kCCBlockSizeAES128
        var outBytes = [UInt8](repeating: 0, count: bufferSize)
        var numBytesDecrypted = 0

        let status = cipherData.withUnsafeBytes { cipherBytes -> CCCryptorStatus in
            keyData.withUnsafeBytes { keyBytes in
                ivData.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyData.count,
                        ivBytes.baseAddress,
                        cipherBytes.baseAddress, cipherData.count,
                        &outBytes, bufferSize,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            Logger.shared.error("板块强度解密: CCCrypt失败 status=\(status)")
            return nil
        }

        let decrypted = Data(bytes: outBytes, count: numBytesDecrypted)
        return String(data: decrypted, encoding: .utf8)
    }

    private static func hexToData(_ hex: String) -> Data? {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
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
