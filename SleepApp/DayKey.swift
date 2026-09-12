import Foundation

/// Canonical conversion for the persisted `yyyy-MM-dd` keys shared by health,
/// projection, and model records. Callers choose the time zone explicitly when
/// converting a key to or from an instant; day-to-day arithmetic is performed
/// in GMT so device travel cannot change feature windows.
enum DayKey {
    static func date(
        from key: String,
        timeZone: TimeZone = .gmt
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
        guard let startDate = date(from: start), let endDate = date(from: end) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.dateComponents([.day], from: startDate, to: endDate).day
    }
}
