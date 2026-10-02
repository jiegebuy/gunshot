import Foundation

public struct GSUploadFileState: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var uploaded: Int64
    public var total: Int64
    public var speed: Int64?
    public var phase: Int
    public var acknowledged: Bool
    public var livePhoto: Bool
    enum CodingKeys: String, CodingKey {
        case id = "i", name = "n", uploaded = "b", total = "t", speed = "r", phase = "s", acknowledged = "a", livePhoto = "l"
    }
    public var fraction: Double? { total > 0 ? min(1, max(0, Double(uploaded) / Double(total))) : nil }
    public var percent: Int? { fraction.map { Int(($0 * 100).rounded(.down)) } }

    public init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.id = String(id.prefix(64))
        let clean = (row["name"] as? String ?? "").components(separatedBy: .controlCharacters).joined(separator: " ")
        // Bound UTF-8 bytes, not UTF-16 length, to keep all twelve files below
        // ActivityKit's shared 4 KB attributes/content limit, including CJK names.
        var short = ""
        for character in clean {
            if (short + String(character)).utf8.count > 42 { break }
            short.append(character)
        }
        name = short.isEmpty ? "GoToHP" : short
        total = max(0, (row["total"] as? NSNumber)?.int64Value ?? 0)
        uploaded = max(0, (row["uploaded"] as? NSNumber)?.int64Value ?? 0)
        if total > 0 { uploaded = min(uploaded, total) }
        speed = (row["speed"] as? NSNumber).map { max(0, $0.int64Value) }
        acknowledged = (row["measurement"] as? String) == "acknowledged"
        livePhoto = (row["livePhoto"] as? Bool) ?? false
        switch row["state"] as? String {
        case "preparing": phase = 1
        case "committing": phase = 2
        case "retrying": phase = 3
        case "waiting_source": phase = 4
        default: phase = total > 0 && uploaded == total ? 2 : 0
        }
    }
}

public struct GSUploadVisualState: Codable, Hashable {
    public var files: [GSUploadFileState]
    public var speed: Int64?
    public var history: [Int64]
    public var waiting: Int
    public var status: Int // 0 active, 1 finished, 2 stopped, 3 unavailable
    public var observedAt: Date
    public var movement: Int

    public init(files: [GSUploadFileState] = [], speed: Int64? = nil, history: [Int64] = [], waiting: Int = 0, status: Int = 0, observedAt: Date = Date(), movement: Int = 0) {
        self.files = files; self.speed = speed; self.history = history
        self.waiting = waiting; self.status = status; self.observedAt = observedAt; self.movement = movement
    }
}

public struct GSUploadVisualReducer {
    public private(set) var state = GSUploadVisualState()
    public init() {}

    public mutating func update(_ payload: [String: Any]) -> GSUploadVisualState {
        let files = ((payload["uploads"] as? [[String: Any]]) ?? []).prefix(12).compactMap(GSUploadFileState.init)
        let time = (payload["sampledAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970 * 1000
        let observedAt = Date(timeIntervalSince1970: time / 1000)
        guard observedAt >= state.observedAt || state.files.isEmpty else { return state }
        let old = Dictionary(uniqueKeysWithValues: state.files.map { ($0.id, $0.uploaded) })
        let moved = files.contains { file in old[file.id].map { file.uploaded > $0 } ?? false }
        let measured = files.compactMap(\.speed)
        let speed = measured.isEmpty || measured.count != files.count ? nil : measured.reduce(Int64(0)) { sum, value in
            let (next, overflow) = sum.addingReportingOverflow(value)
            return overflow ? Int64.max : next
        }
        var history = state.history
        if observedAt.timeIntervalSince(state.observedAt) >= 1, let speed { history.append(speed) }
        if history.count > 16 { history.removeFirst(history.count - 16) }
        let profiles = payload["profiles"] as? [String: [String: Any]] ?? [:]
        let outstanding = profiles.values.reduce(0) { count, profile in
            let states = profile["states"] as? [String: NSNumber] ?? [:]
            return count + ["importing", "pending", "preparing", "uploading", "committing"].reduce(0) { $0 + (states[$1]?.intValue ?? 0) }
        }
        state = GSUploadVisualState(files: files, speed: speed, history: history, waiting: max(0, outstanding - files.count), observedAt: observedAt, movement: state.movement + (moved ? 1 : 0))
        return state
    }
}

public enum GSUploadText {
    public static func text(_ key: String, language: String) -> String {
        let zh = ["Uploads":"正在上传", "Recent speed":"近期速率", "Waiting":"排队", "Preparing":"准备中", "Confirming":"确认中", "Retrying":"重试中", "Source":"等待原文件", "Received":"已接收", "Sent":"已发送", "No transfers":"正在准备原文件", "Finished":"上传任务完成", "Stopped":"上传任务已停止", "Stale":"等待更新", "Unknown":"大小未知", "files":"项", "Recent 12 seconds":"最近 12 秒"]
        let ja = ["Uploads":"アップロード", "Recent speed":"最近の速度", "Waiting":"待機", "Preparing":"準備中", "Confirming":"確認中", "Retrying":"再試行中", "Source":"データ待ち", "Received":"受信済み", "Sent":"送信済み", "No transfers":"オリジナルを準備中", "Finished":"アップロード完了", "Stopped":"アップロード停止", "Stale":"更新待ち", "Unknown":"サイズ不明", "files":"件", "Recent 12 seconds":"直近12秒"]
        let vi = ["Uploads":"Đang tải lên", "Recent speed":"Tốc độ gần đây", "Waiting":"Đợi", "Preparing":"Chuẩn bị", "Confirming":"Xác nhận", "Retrying":"Thử lại", "Source":"Đợi dữ liệu", "Received":"Đã nhận", "Sent":"Đã gửi", "No transfers":"Đang chuẩn bị tệp gốc", "Finished":"Đã tải lên", "Stopped":"Đã dừng tải lên", "Stale":"Đợi cập nhật", "Unknown":"Chưa rõ kích thước", "files":"tệp", "Recent 12 seconds":"12 giây gần đây"]
        let catalog = language.hasPrefix("zh") ? zh : language.hasPrefix("ja") ? ja : language.hasPrefix("vi") ? vi : [:]
        return catalog[key] ?? key
    }
    public static func rate(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + "/s"
    }
}
