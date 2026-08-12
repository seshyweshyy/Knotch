//
//  MonthGridView.swift
//  Knotch
//

import Defaults
import SwiftUI

private struct GridDay: Identifiable {
    let date: Date
    let dayNumber: Int
    let isCurrentMonth: Bool
    var id: Date { date }
}

struct MonthGridView: View {
    @Binding var selectedDate: Date

    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.compactCalendarShowEventIndicators) private var showEventIndicators
    @State private var monthEvents: [EventModel] = []

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]
    private let maxIndicatorColors = 3

    private var displayedMonth: Date {
        calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
    }

    // Combines month/year with showEventIndicators so toggling the setting
    // retriggers the fetch too.
    private var monthTaskID: String {
        let comps = calendar.dateComponents([.year, .month], from: displayedMonth)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(showEventIndicators)"
    }

    // Caps each individual day at maxIndicatorColors distinct calendar
    // colors (first-seen order for that day); reminders are always
    // excluded, no toggle for it. A multi-day event (e.g. a week-long
    // all-day one) marks every day it spans, not just its start day —
    // clamped to the visible month so a long-running event can't loop for
    // longer than that.
    private var indicatorColorsByDay: [Date: [Color]] {
        guard showEventIndicators, !monthEvents.isEmpty else { return [:] }
        let relevantEvents = monthEvents.filter { !$0.type.isReminder }
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth) else { return [:] }
        let monthStart = monthInterval.start
        let monthEnd = calendar.startOfDay(for: monthInterval.end.addingTimeInterval(-1))

        var result: [Date: [NSColor]] = [:]
        for event in relevantEvents {
            let color = event.calendar.color
            let eventStart = calendar.startOfDay(for: event.start)
            // End is exclusive (a week-long all-day event's end sits at the
            // start of the following day), so back it up before taking its day.
            let eventEnd = calendar.startOfDay(for: event.end.addingTimeInterval(-1))
            var day = max(eventStart, monthStart)
            let lastDay = min(eventEnd, monthEnd)
            while day <= lastDay {
                var colors = result[day, default: []]
                if !colors.contains(color) && colors.count < maxIndicatorColors {
                    colors.append(color)
                    result[day] = colors
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        return result.mapValues { $0.map(Color.init) }
    }

    private var gridDays: [GridDay] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: selectedDate) else { return [] }
        let firstOfMonth = monthInterval.start
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 30
        // Calendar.component(.weekday) is 1-based starting Sunday, matching the Su-Sa header.
        let leadingCount = calendar.component(.weekday, from: firstOfMonth) - 1

        var days: [GridDay] = []

        if leadingCount > 0 {
            for offset in stride(from: leadingCount, to: 0, by: -1) {
                let date = calendar.date(byAdding: .day, value: -offset, to: firstOfMonth) ?? firstOfMonth
                days.append(GridDay(date: date, dayNumber: calendar.component(.day, from: date), isCurrentMonth: false))
            }
        }

        for dayOffset in 0..<daysInMonth {
            let date = calendar.date(byAdding: .day, value: dayOffset, to: firstOfMonth) ?? firstOfMonth
            days.append(GridDay(date: date, dayNumber: dayOffset + 1, isCurrentMonth: true))
        }

        let trailingCount = (7 - days.count % 7) % 7
        if trailingCount > 0, let lastDate = days.last?.date {
            for offset in 1...trailingCount {
                let date = calendar.date(byAdding: .day, value: offset, to: lastDate) ?? lastDate
                days.append(GridDay(date: date, dayNumber: calendar.component(.day, from: date), isCurrentMonth: false))
            }
        }

        return days
    }

    // gridDays is always padded to a multiple of 7 (leading + trailing filler
    // days), so this always divides evenly into full weeks.
    private var gridRows: [[GridDay]] {
        stride(from: 0, to: gridDays.count, by: 7).map { start in
            Array(gridDays[start..<min(start + 7, gridDays.count)])
        }
    }

    var body: some View {
        let indicatorColors = indicatorColorsByDay

        VStack(alignment: .trailing, spacing: 4) {
            Text(displayedMonth.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .bold, design: .default))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .trailing)

            // A plain Grid, not LazyVGrid — rows move as one block instead of
            // popping in independently during the panel's swap transition.
            // Indicators tighten row spacing so 6-row months still fit.
            Grid(horizontalSpacing: 0, verticalSpacing: showEventIndicators ? 0 : 1.5) {
                GridRow {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(.system(size: 9, weight: .semibold, design: .default))
                            .foregroundColor(symbol == "Su" || symbol == "Sa" ? Color(white: 0.45) : .white)
                    }
                }

                ForEach(Array(gridRows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { day in
                            dayCell(
                                day,
                                indicatorColors: day.isCurrentMonth
                                    ? (indicatorColors[calendar.startOfDay(for: day.date)] ?? [])
                                    : []
                            )
                        }
                    }
                }
            }
        }
        .task(id: monthTaskID) {
            guard showEventIndicators else {
                monthEvents = []
                return
            }
            monthEvents = await calendarManager.fetchMonthEvents(for: displayedMonth)
        }
    }

    private func isWeekend(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private func dayCell(_ day: GridDay, indicatorColors: [Color]) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDate)
        // The selection circle covers the same spot the dashes would sit
        // just under, so a selected day's own indicators are hidden rather
        // than drawn alongside it.
        let visibleIndicatorColors = isSelected ? [] : indicatorColors

        return Button {
            // The circle's own pop animates fine via .animation(value:), but
            // CompactCalendarView's weekday-text .transition() only fires
            // inside an animated transaction — it needs this wrapped here,
            // not just an .animation(value:) modifier on the text itself.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                selectedDate = day.date
            }
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    // Same isToday/isSelected color language AND pop animation as
                    // WheelPicker's dateCircle.
                    Circle()
                        .fill(
                            isToday && isSelected  ? Color.red
                          : !isToday && isSelected ? Color.white
                          :                          Color.clear
                        )
                        .frame(width: 16, height: 16)
                        .scaleEffect(isSelected ? 1.0 : 0.5)
                        .opacity(isSelected ? 1.0 : 0.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isSelected)

                    // Adjacent-month cells keep their spot in the grid (so column
                    // alignment doesn't shift) but show no number at all, rather
                    // than a dimmed one.
                    if day.isCurrentMonth {
                        Text("\(day.dayNumber)")
                            .font(.system(size: 10, weight: .semibold, design: .default))
                            .foregroundColor(
                                isToday && isSelected    ? Color.white
                              : !isToday && isSelected   ? Color.black
                              : isToday                  ? Color.red
                              : isWeekend(day.date)      ? Color(white: 0.45)
                              :                            Color.white
                            )
                    }
                }
                // Trimmed to the circle's own diameter (no slack) when
                // indicators show, so the row below sits as close as possible.
                .frame(maxWidth: .infinity, minHeight: showEventIndicators ? 16 : 16.5)

                // Reserved for every cell, even ones with nothing to show,
                // so mixed rows stay vertically aligned.
                if showEventIndicators {
                    HStack(spacing: 2) {
                        ForEach(Array(visibleIndicatorColors.enumerated()), id: \.offset) { _, color in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(color)
                                .frame(width: 3, height: 2)
                        }
                    }
                    .frame(height: 2)
                    // Render-only shift into the circle's empty space below
                    // the centered digit — doesn't affect Grid row sizing.
                    .offset(y: -3)
                }
            }
            // Without this, the tap target shrinks to just the visible glyph
            // (the day number, or the filled circle when selected) instead of
            // the full cell — on unselected days that's a tiny sliver, since
            // the circle itself is invisible (clear fill) until selected.
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!day.isCurrentMonth)
    }
}

#Preview {
    MonthGridView(selectedDate: .constant(Date()))
        .frame(width: 165)
        .padding()
        .background(.black)
}
