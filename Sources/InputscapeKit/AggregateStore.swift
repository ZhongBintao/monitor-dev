import Foundation

/// 本地聚合存储协议。实现必须只持久化 DailyRecord 允许的聚合字段。
public protocol AggregateStore: Sendable {
    func save(_ record: DailyRecord) throws
    func load(day: String) -> DailyRecord?
    /// 取 endDay（不含）之前最近的 count 天记录。
    func loadRecentDays(_ count: Int, before endDay: String) -> [DailyRecord]
    func deleteDay(_ day: String) throws
    func deleteAll() throws
    func listDays() -> [String]
}

/// 按日 JSON 文件存储：`<dir>/YYYY-MM-DD.json`。
/// 原子写入；仅在首版聚合数据量极小的情况下使用（符合设计文档 §10）。
public struct JSONDayStore: AggregateStore {

    public let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "inputscape.store", qos: .utility)

    public init(directory: URL) {
        self.directory = directory
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.decoder = d
    }

    /// 默认位置：~/Library/Application Support/Inputscape/days
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Inputscape/days", isDirectory: true)
    }

    private func fileURL(for day: String) -> URL {
        directory.appendingPathComponent("\(day).json")
    }

    private static let dayPattern = "^\\d{4}-\\d{2}-\\d{2}$"

    public func save(_ record: DailyRecord) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(record)
            try data.write(to: fileURL(for: record.date), options: .atomic)
        }
    }

    public func load(day: String) -> DailyRecord? {
        queue.sync {
            loadUnlocked(day: day)
        }
    }

    private func loadUnlocked(day: String) -> DailyRecord? {
        guard day.range(of: Self.dayPattern, options: .regularExpression) != nil else { return nil }
        guard let data = try? Data(contentsOf: fileURL(for: day)) else { return nil }
        return try? decoder.decode(DailyRecord.self, from: data)
    }

    public func loadRecentDays(_ count: Int, before endDay: String) -> [DailyRecord] {
        queue.sync {
            guard count > 0 else { return [] }
            let days = listDaysUnlocked().filter { $0 < endDay }.suffix(count)
            return days.compactMap { loadUnlocked(day: $0) }
        }
    }

    public func deleteDay(_ day: String) throws {
        try queue.sync {
            guard day.range(of: Self.dayPattern, options: .regularExpression) != nil else { return }
            let url = fileURL(for: day)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func deleteAll() throws {
        try queue.sync {
            let fm = FileManager.default
            guard fm.fileExists(atPath: directory.path) else { return }
            for day in listDaysUnlocked() {
                try fm.removeItem(at: fileURL(for: day))
            }
        }
    }

    public func listDays() -> [String] {
        queue.sync { listDaysUnlocked() }
    }

    private func listDaysUnlocked() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter { $0.range(of: Self.dayPattern, options: .regularExpression) != nil }
            .sorted()
    }
}
