import Foundation

/// 当日 2–3 句结论。只用已验证或已明确标为近似的信号。
public enum DayNotes {

    public static func make(report: DayReport, rhythm: Rhythm.Summary?, now: Date = Date()) -> [String] {
        var notes: [String] = []

        if report.isLegacyOnly {
            notes.append("这一天来自旧版记录：只有全天总量，按住重复被算作了按键，活跃时长偏低。")
            return notes
        }

        if let r = rhythm {
            let long = r.longStretches
            if let longest = r.longest {
                if long.count >= 2 {
                    notes.append("有 \(long.count) 段连续操作超过 1 小时没有休息，最长一段 \(clock(longest.start))–\(clock(longest.end))（\(duration(minutes: longest.length))）。")
                } else if long.count == 1 {
                    notes.append("最长一段连续操作 \(clock(longest.start))–\(clock(longest.end))，持续 \(duration(minutes: longest.length)) 没有休息。")
                } else if r.stretches.count > 1 {
                    notes.append("最长一段连续操作 \(duration(minutes: longest.length))，其余时间都有 5 分钟以上的休息。")
                }
            }
            if r.lateNightMinutes >= 10, let last = r.lastActiveMinute {
                notes.append("23 点后还操作了 \(duration(minutes: r.lateNightMinutes))，最后一次输入在 \(clock(last + 1))。")
            }
        }

        if let share = report.chineseShare, report.totals.keyPresses >= 200 {
            notes.append("中文输入法开启时的按键占 \(percent(share))。")
        }

        if let peak = peakHour(report), notes.count < 3 {
            notes.append("按键最多的时段是 \(peak.label)（\(peak.keys.formatted()) 次）。")
        }

        let repeats = Int(report.totals[.keyRepeat])
        if repeats >= 100, notes.count < 3 {
            notes.append("按住不放产生的重复输入有 \(repeats.formatted()) 次，未计入按键数。")
        }
        return Array(notes.prefix(3))
    }

    // MARK: 格式

    public static func clock(_ minute: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(minute) * 60)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    public static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }

    public static func duration(seconds: Double) -> String {
        duration(minutes: Int((seconds / 60).rounded()))
    }

    public static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func peakHour(_ report: DayReport) -> (label: String, keys: Int)? {
        guard report.range.isSingleDay else { return nil }
        var byHour: [Int: Int] = [:]
        for (m, c) in report.minutes { byHour[m / 60, default: 0] += c.keyPresses }
        guard let best = byHour.max(by: { $0.value < $1.value }), best.value >= 100 else { return nil }
        return ("\(clock(best.key * 60))–\(clock(best.key * 60 + 60))", best.value)
    }
}
