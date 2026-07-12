import Foundation

/// Manual "time ago" formatting shared by PostListVC and PostVC —
/// RelativeDateTimeFormatter is iOS13+, unavailable here.
struct RelativeTime {
    static func string(from date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let minute = 60.0, hour = 3600.0, day = 86400.0
        if seconds < minute { return "just now" }
        if seconds < hour { return "\(Int(seconds / minute))m ago" }
        if seconds < day { return "\(Int(seconds / hour))h ago" }
        return "\(Int(seconds / day))d ago"
    }
}
