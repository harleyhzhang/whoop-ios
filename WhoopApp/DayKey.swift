import Foundation

/// A validated `yyyy-MM-dd` key shared by health, projection, and model
/// records. The raw string remains the SQLite/JSON representation, while
/// comparisons and calendar arithmetic operate only on validated values.
struct DayKey: RawRepresentable, Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible
{
    let rawValue: String

    init?(rawValue: String) {
        guard Self.parsedDate(from: rawValue, timeZone: .gmt) != nil else { return nil }
        self.rawValue = rawValue
    }

    init(date: Date, timeZone: TimeZone) {
        rawValue = Self.formattedString(from: date, timeZone: timeZone)
    }

    var description: String { rawValue }

    static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        // Fixed-width Gregorian keys sort chronologically byte-for-byte.
        lhs.rawValue < rhs.rawValue
    }

    func date(timeZone: TimeZone = .gmt) -> Date? {
        Self.parsedDate(from: rawValue, timeZone: timeZone)
    }

    func dayGap(to end: DayKey) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let startDate = date(), let endDate = end.date() else { return nil }
        return calendar.dateComponents(
            [.day],
            from: startDate,
            to: endDate
        ).day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = DayKey(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid day key: \(rawValue)"
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Compatibility boundary for persisted string models. New behavioral
    /// code should initialize `DayKey` and retain the typed value.
    static func date(
        from key: String,
        timeZone: TimeZone = .gmt
    ) -> Date? {
        guard let key = DayKey(rawValue: key) else { return nil }
        return key.date(timeZone: timeZone)
    }

    private static func parsedDate(
        from key: String,
        timeZone: TimeZone
    ) -> Date? {
        let values = key.split(separator: "-", omittingEmptySubsequences: false)
        guard values.count == 3,
            values[0].count == 4,
            values[1].count == 2,
            values[2].count == 2,
            let year = Int(values[0]),
            let month = Int(values[1]),
            let day = Int(values[2])
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard
            let date = calendar.date(
                from: DateComponents(
                    timeZone: timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: 12
                ))
        else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else {
            return nil
        }
        return date
    }

    static func string(
        from date: Date,
        timeZone: TimeZone
    ) -> String {
        DayKey(date: date, timeZone: timeZone).rawValue
    }

    private static func formattedString(
        from date: Date,
        timeZone: TimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func dayGap(from start: String, to end: String) -> Int? {
        guard let start = DayKey(rawValue: start), let end = DayKey(rawValue: end) else {
            return nil
        }
        return start.dayGap(to: end)
    }
}
