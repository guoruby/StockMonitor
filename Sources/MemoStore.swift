import Foundation

class MemoStore {
    static let shared = MemoStore()

    private let fileURL: URL

    private(set) var memos: [MemoItem] = []

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("StockMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("memos.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([MemoItem].self, from: data) else {
            memos = []
            return
        }
        memos = items
    }

    func save() {
        if let data = try? JSONEncoder().encode(memos) {
            try? data.write(to: fileURL)
        }
    }

    func add(_ memo: MemoItem) {
        memos.append(memo)
        save()
    }

    func update(id: String, text: String? = nil, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) {
        guard let idx = memos.firstIndex(where: { $0.id == id }) else { return }
        if let text = text { memos[idx].text = text }
        if let x = x { memos[idx].x = x }
        if let y = y { memos[idx].y = y }
        if let width = width { memos[idx].width = width }
        if let height = height { memos[idx].height = height }
        save()
    }

    func remove(id: String) {
        memos.removeAll { $0.id == id }
        save()
    }
}
