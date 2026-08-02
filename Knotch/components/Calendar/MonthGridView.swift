//
//  MonthGridView.swift
//  Knotch
//

import SwiftUI

private struct GridDay: Identifiable {
    let date: Date
    let dayNumber: Int
    let isCurrentMonth: Bool
    var id: Date { date }
}

struct MonthGridView: View {
    @Binding var selectedDate: Date

    private let calendar = Calendar.current
    private let weekdaySymbols = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]

    private var displayedMonth: Date {
        calendar.dateInterval(of: .month, for: selectedDate)?.start ?? selectedDate
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
        VStack(alignment: .trailing, spacing: 4) {
            Text(displayedMonth.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .bold, design: .default))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .trailing)

            // A plain Grid, not LazyVGrid — the lazy container recomputes
            // which rows are "visible" as its enclosing view moves during the
            // music/calendar swap transition, which made rows pop in and out
            // independently instead of moving as one solid block.
            Grid(horizontalSpacing: 0, verticalSpacing: 1.5) {
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
                            dayCell(day)
                        }
                    }
                }
            }
        }
    }

    private func isWeekend(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    private func dayCell(_ day: GridDay) -> some View {
        let isToday = calendar.isDateInToday(day.date)
        let isSelected = calendar.isDate(day.date, inSameDayAs: selectedDate)

        return Button {
            // The circle's own pop animates fine via .animation(value:), but
            // CompactCalendarView's weekday-text .transition() only fires
            // inside an animated transaction — it needs this wrapped here,
            // not just an .animation(value:) modifier on the text itself.
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                selectedDate = day.date
            }
        } label: {
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
            .frame(maxWidth: .infinity, minHeight: 16.5)
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
