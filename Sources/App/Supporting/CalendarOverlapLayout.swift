// Purpose: Places overlapping calendar events side by side (Outlook style) instead of on top of
//          each other: every event gets a column and a column span within its day.
// Dependencies: none (pure geometry over start and end dates)
// Used by: Sources/App/Views/WeekCalendarView.swift (day columns of the week grid)
// Notes: Events that overlap directly or through a chain form a cluster; the cluster is split
//        into as many equal columns as it needs at its busiest point, so events of one cluster
//        line up. An event then widens to the right over columns that stay free for its whole
//        time, which keeps the lone event next to a short clash readable. Overlap is judged on
//        the drawn height (`minimumDuration`), not the real end, because a 10-minute event is
//        drawn taller than 10 minutes and would otherwise cover the next one.

import Foundation

enum CalendarOverlapLayout {
    struct Item: Equatable {
        let id: String
        let start: Date
        let end: Date
    }

    /// Horizontal slot of one event: it starts in `column` and covers `span` of `columns`.
    struct Slot: Equatable {
        let column: Int
        let span: Int
        let columns: Int

        /// Left edge as a fraction of the day column's width.
        var leadingFraction: CGFloat { CGFloat(column) / CGFloat(columns) }
        /// Width as a fraction of the day column's width.
        var widthFraction: CGFloat { CGFloat(span) / CGFloat(columns) }
    }

    /// Slots for `items`, keyed by item ID. Items ending before they start count as `minimumDuration` long.
    static func slots(for items: [Item], minimumDuration: TimeInterval = 0) -> [String: Slot] {
        let sorted = items.sorted {
            $0.start != $1.start ? $0.start < $1.start : visualEnd($0, minimumDuration) > visualEnd($1, minimumDuration)
        }

        var result: [String: Slot] = [:]
        var cluster: [Item] = []
        var clusterEnd = Date.distantPast

        for item in sorted {
            if !cluster.isEmpty && item.start >= clusterEnd {
                place(cluster, minimumDuration: minimumDuration, into: &result)
                cluster.removeAll()
                clusterEnd = .distantPast
            }
            cluster.append(item)
            clusterEnd = max(clusterEnd, visualEnd(item, minimumDuration))
        }
        if !cluster.isEmpty { place(cluster, minimumDuration: minimumDuration, into: &result) }
        return result
    }

    private static func visualEnd(_ item: Item, _ minimumDuration: TimeInterval) -> Date {
        max(item.end, item.start.addingTimeInterval(minimumDuration))
    }

    /// Assigns columns within one cluster (items sorted by start): each item takes the first
    /// column whose last item has ended, or opens a new one.
    private static func place(_ cluster: [Item], minimumDuration: TimeInterval, into result: inout [String: Slot]) {
        var columnEnds: [Date] = []
        var columnOf: [Int] = []
        for item in cluster {
            if let free = columnEnds.firstIndex(where: { $0 <= item.start }) {
                columnEnds[free] = visualEnd(item, minimumDuration)
                columnOf.append(free)
            } else {
                columnEnds.append(visualEnd(item, minimumDuration))
                columnOf.append(columnEnds.count - 1)
            }
        }

        let columns = columnEnds.count
        for (index, item) in cluster.enumerated() {
            let column = columnOf[index]
            let start = item.start
            let end = visualEnd(item, minimumDuration)
            var span = 1
            // Widen while the next column has nothing overlapping this item's time.
            while column + span < columns {
                let next = column + span
                let blocked = cluster.indices.contains { other in
                    columnOf[other] == next
                        && cluster[other].start < end
                        && visualEnd(cluster[other], minimumDuration) > start
                }
                if blocked { break }
                span += 1
            }
            result[item.id] = Slot(column: column, span: span, columns: columns)
        }
    }
}
