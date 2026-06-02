import Foundation

class Logger {
    static let shared = Logger()
    
    private let logDir: URL
    private let logFile: URL
    private let queue = DispatchQueue(label: "com.stockmonitor.logger")
    
    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StockMonitor", isDirectory: true)
        logDir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        logFile = dir.appendingPathComponent("stock_monitor_\(df.string(from: Date())).log")
    }
    
    func info(_ message: String) {
        write(level: "INFO", message: message)
    }
    
    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }
    
    func debug(_ message: String) {
        write(level: "DEBUG", message: message)
    }
    
    private func write(level: String, message: String) {
        queue.async {
            let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let line = "[\(timestamp)] [\(level)] \(message)\n"
            
            guard let data = line.data(using: .utf8) else { return }
            
            if FileManager.default.fileExists(atPath: self.logFile.path) {
                if let handle = try? FileHandle(forWritingTo: self.logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: self.logFile)
            }
        }
    }
    
    var logFilePath: String {
        logFile.path
    }
    
    var logDirPath: String {
        logDir.path
    }
}
