import Foundation
import Vision
import Quartz
import AppKit

class OCREngine {
    static let shared = OCREngine()

    func recognize(region: ScreenRegion) -> [OCRResult] {
        let displayID = CGMainDisplayID()
        let rect = CGRect(x: region.left, y: region.top, width: region.width, height: region.height)

        Logger.shared.info("OCR: 截取区域 left=\(region.left) top=\(region.top) width=\(region.width) height=\(region.height)")

        guard let cgImage = CGDisplayCreateImage(displayID, rect: rect) else {
            Logger.shared.error("OCR: CGDisplayCreateImage 返回 nil，可能没有屏幕录制权限或区域无效")
            return []
        }

        Logger.shared.info("OCR: 截图成功，图片尺寸 \(cgImage.width)x\(cgImage.height)")

        if cgImage.width <= 1 || cgImage.height <= 1 {
            Logger.shared.error("OCR: 截图尺寸异常 (\(cgImage.width)x\(cgImage.height))，可能没有屏幕录制权限")
            return []
        }

        saveDebugImage(cgImage: cgImage)

        var results: [OCRResult] = []
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                Logger.shared.error("OCR: VNRecognizeTextRequest 错误: \(error.localizedDescription)")
                semaphore.signal()
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                Logger.shared.error("OCR: 无法获取识别结果 observations")
                semaphore.signal()
                return
            }

            Logger.shared.info("OCR: 识别到 \(observations.count) 个文本块")

            for obs in observations {
                if let candidate = obs.topCandidates(1).first {
                    let box = obs.boundingBox
                    results.append(OCRResult(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: CGRect(
                            x: box.origin.x,
                            y: box.origin.y,
                            width: box.width,
                            height: box.height
                        )
                    ))
                    Logger.shared.debug("OCR: 文本=\"\(candidate.string)\" 置信度=\(String(format: "%.0f%%", candidate.confidence * 100))")
                }
            }
            semaphore.signal()
        }

        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Logger.shared.error("OCR: handler.perform 异常: \(error.localizedDescription)")
        }
        semaphore.wait()

        if results.isEmpty {
            Logger.shared.error("OCR: 未识别到任何文字，请检查: 1)屏幕录制权限 2)OCR区域是否正确 3)区域是否有文字")
        } else {
            let allText = results.map { $0.text }.joined(separator: " | ")
            Logger.shared.info("OCR: 识别完成，共\(results.count)个文本块: \(allText)")
        }

        return results
    }

    func parseResults(_ results: [OCRResult]) -> ParsedOCR {
        let fullText = results.map { $0.text }.joined(separator: " ")
        Logger.shared.info("OCR解析: 原始文本=\"\(fullText)\"")

        var code: String?
        var name: String = ""
        var avgPrice: Double?
        var currentPrice: Double?

        let codePattern = try? NSRegularExpression(pattern: "\\b(60[0-5]\\d{3}|60[89]\\d{3}|300\\d{3}|00[0-3]\\d{3}|000\\d{3})\\b")
        if let match = codePattern?.firstMatch(in: fullText, range: NSRange(fullText.startIndex..., in: fullText)) {
            code = String(fullText[Range(match.range, in: fullText)!])
        }

        let avgPatterns = [
            "均价[:：\\s]*([\\d.]+)",
            "均[价份][:：\\s]*([\\d.]+)",
            "均价\\s+([\\d.]+)",
            "均价([\\d.]+)"
        ]
        for pattern in avgPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: fullText, range: NSRange(fullText.startIndex..., in: fullText)) {
                let numStr = String(fullText[Range(match.range(at: 1), in: fullText)!])
                avgPrice = Double(numStr)
                if avgPrice != nil {
                    Logger.shared.info("OCR解析: 均价匹配模式\"\(pattern)\" → \(numStr)")
                    break
                }
            }
        }

        let currentPatterns = [
            "(?:最新|现价|当前)[:：\\s]*([\\d.]+)",
            "(?:最新|现价|当前)\\s+([\\d.]+)",
            "(?:最新|现价|当前)([\\d.]+)"
        ]
        for pattern in currentPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: fullText, range: NSRange(fullText.startIndex..., in: fullText)) {
                let numStr = String(fullText[Range(match.range(at: 1), in: fullText)!])
                currentPrice = Double(numStr)
                if currentPrice != nil {
                    Logger.shared.info("OCR解析: 最新价匹配模式\"\(pattern)\" → \(numStr)")
                    break
                }
            }
        }

        if avgPrice == nil || currentPrice == nil {
            Logger.shared.info("OCR解析: 关键词匹配不完整，尝试智能提取价格数字")
            let prices = extractPrices(from: results)
            Logger.shared.info("OCR解析: 智能提取到的价格: \(prices.map { String(format: "%.2f", $0) })")

            if avgPrice == nil && prices.count >= 2 {
                avgPrice = prices[0]
                Logger.shared.info("OCR解析: 均价取第1个价格: \(String(format: "%.2f", avgPrice!))")
            }
            if currentPrice == nil && prices.count >= 1 {
                currentPrice = prices[prices.count - 1]
                Logger.shared.info("OCR解析: 最新价取最后1个价格: \(String(format: "%.2f", currentPrice!))")
            }
        }

        let excludeNames: Set<String> = ["均价", "最新", "现价", "当前", "均份", "涨跌", "涨幅", "跌幅", "开盘", "收盘", "最高", "最低", "成交", "换手", "市盈", "市净", "振幅", "量比"]
        let nameRegex = try? NSRegularExpression(pattern: "[\\p{Han}]{2,4}")
        if let regex = nameRegex {
            let matches = regex.matches(in: fullText, range: NSRange(fullText.startIndex..., in: fullText))
            for match in matches {
                let candidate = String(fullText[Range(match.range, in: fullText)!])
                if !excludeNames.contains(candidate) {
                    name = candidate
                    Logger.shared.info("OCR解析: 名称匹配\"\(candidate)\"")
                    break
                }
            }
        }

        let parsed = ParsedOCR(code: code, name: name, avgPrice: avgPrice, currentPrice: currentPrice, rawText: fullText)
        Logger.shared.info("OCR解析结果: 代码=\(code ?? "无") 名称=\(name.isEmpty ? "无" : name) 均价=\(avgPrice.map { String(format: "%.2f", $0) } ?? "无") 最新=\(currentPrice.map { String(format: "%.2f", $0) } ?? "无")")

        return parsed
    }

    private func extractPrices(from results: [OCRResult]) -> [Double] {
        var prices: [Double] = []
        let timeUnits = ["分", "秒", "时", "天", "日", "周", "月", "年", "分钟", "小时"]
        let codePattern = try? NSRegularExpression(pattern: "^[036]\\d{5}$")
        let numPattern = try? NSRegularExpression(pattern: "(\\d+\\.?\\d*)")

        for result in results {
            let text = result.text
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            if trimmed.hasSuffix("分") || trimmed.hasSuffix("秒") || trimmed.hasSuffix("时") ||
               trimmed.hasSuffix("天") || trimmed.hasSuffix("日") || trimmed.hasSuffix("周") ||
               trimmed.hasSuffix("月") || trimmed.hasSuffix("年") {
                Logger.shared.debug("OCR解析: 跳过时间文本\"\(trimmed)\"")
                continue
            }

            var isTimeLabel = false
            for unit in timeUnits {
                if trimmed.contains(unit) && !trimmed.contains("均价") && !trimmed.contains("最新") && !trimmed.contains("现价") {
                    let numBeforeUnit = try? NSRegularExpression(pattern: "(\\d+\\.?\\d*)\(unit)")
                    if numBeforeUnit?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                        isTimeLabel = true
                        break
                    }
                }
            }
            if isTimeLabel {
                Logger.shared.debug("OCR解析: 跳过含时间单位的文本\"\(trimmed)\"")
                continue
            }

            let matches = numPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            for match in matches {
                let numStr = String(text[Range(match.range(at: 1), in: text)!])
                if let num = Double(numStr), num > 0 {
                    if let codeRegex = codePattern, codeRegex.firstMatch(in: numStr, range: NSRange(numStr.startIndex..., in: numStr)) != nil {
                        Logger.shared.debug("OCR解析: 跳过股票代码\"\(numStr)\"")
                        continue
                    }
                    if num > 100000 {
                        Logger.shared.debug("OCR解析: 跳过超大数字\(numStr)")
                        continue
                    }
                    prices.append(num)
                }
            }
        }
        return prices
    }

    private func saveDebugImage(cgImage: CGImage) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StockMonitor", isDirectory: true)
        let url = dir.appendingPathComponent("ocr_debug.png")
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        if let tiffData = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try? pngData.write(to: url)
            Logger.shared.debug("OCR: 调试截图已保存到 \(url.path)")
        }
    }
}
