import Foundation

enum DateParse {

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func plain(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = format
        return f
    }

    /// "2024-03-01", "2024-03-01 14:30", "2024-03-01T14:30:00Z" 등을 모두 받아준다.
    /// 날짜만 주어지면 현지 시간대 자정으로 해석한다.
    static func date(from raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)

        if let d = isoWithFraction.date(from: text) { return d }
        if let d = iso.date(from: text) { return d }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd"] {
            if let d = plain(format).date(from: text) { return d }
        }
        return nil
    }

    /// 종료일이 날짜만("2024-03-01") 들어오면 그날 전체를 포함하도록 하루 끝으로 민다.
    static func endDate(from raw: String?) -> Date? {
        guard let raw else { return nil }
        guard let parsed = date(from: raw) else { return nil }
        let dateOnly = raw.trimmingCharacters(in: .whitespaces).count <= 10
        guard dateOnly else { return parsed }
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: parsed) ?? parsed
    }

    private static let output: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    static func iso8601(_ date: Date?) -> String? {
        guard let date else { return nil }
        return output.string(from: date)
    }
}
