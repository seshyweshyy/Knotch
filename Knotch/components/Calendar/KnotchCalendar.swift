//
//  KnotchCalendar.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import AppKit
import Defaults
import SwiftUI

private extension Color {
    // The opaque equivalent of this color at low alpha over a black backdrop
    // — i.e. what the pill's own translucent background tint looks like —
    // but as a solid color, so it stays visible drawn on top of a full-
    // saturation circle of the same base hue instead of blending back into it.
    func opaqueDarkTint(alpha: Double) -> Color {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor(self)
        return Color(red: ns.redComponent * alpha, green: ns.greenComponent * alpha, blue: ns.blueComponent * alpha)
    }

}

// The exact same press-highlight tint EventRowButtonStyle draws behind a
// pressed row — factored out so CompactAllDayPill's circle can reuse the
// identical view instead of a separately reconstructed approximation of it.
private func pillPressTint(_ color: Color) -> some View {
    ZStack {
        Color.white
        color.opacity(0.8)
    }
}

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 3
    var future: Int = 7
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 2  // Number of dates to the left of the selected date
}

struct WheelPicker: View {
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: config.spacing) {
                let spacerNum = config.offset
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        // Leading/trailing spacers sized to match a date cell
                        Spacer()
                            .frame(width: 24, height: 24)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        dateButton(date: date, isSelected: isSelected, id: index) {
                            selectedDate = date
                            byClick = true
                            withAnimation {
                                scrollPosition = index
                            }
                            if Defaults[.enableHaptics] {
                                haptics.toggle()
                            }
                        }
                    }
                }
            }
            .frame(height: 50)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
        .safeAreaPadding(.horizontal)
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { oldValue, newValue in
            if !byClick {
                handleScrollChange(newValue: newValue, config: config)
            } else {
                byClick = false
            }
        }
        .onAppear {
            scrollToToday(config: config)
        }
        // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                withAnimation {
                    scrollPosition = targetIndex
                }
            }
        }
    }

    private func dateButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return Button {
            if isSelected {
                let scheme: String
                switch Defaults[.calendarApp] {
                case .fantastical:  scheme = "x-fantastical3://"
                case .busyCal:      scheme = "busycal://"
                case .notionCal:    scheme = "notion://"
                case .apple:        scheme = "ical://"
                }
                if let url = URL(string: scheme) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                onClick()
            }
        } label: {
            VStack(spacing: 6) {
                dayText(date: dateToString(for: date), isToday: isToday, isSelected: isSelected)
                dateCircle(date: date, isToday: isToday, isSelected: isSelected)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 1.25)
        }
        .buttonStyle(PlainButtonStyle())
        .id(id)
    }

    private func dayText(date: String, isToday: Bool, isSelected: Bool) -> some View {
        Text(date)
            .font(.caption)
            .foregroundColor(isSelected ? .white : Color(white: 0.55))
            .animation(.easeInOut(duration: 0.2), value: isSelected)
    }

    private func dateCircle(date: Date, isToday: Bool, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    isToday && isSelected  ? Color.red
                  : !isToday && isSelected ? Color.white
                  :                          Color.clear
                )
                .frame(width: 26, height: 26)
                .scaleEffect(isSelected ? 1.0 : 0.5)
                .opacity(isSelected ? 1.0 : 0.0)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isSelected)

            Text("\(date.date)")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(
                    isToday && isSelected  ? Color.white             // accent circle → white number
                  : !isToday && isSelected ? Color.black             // white circle → black number
                  : isToday                ? Color.red               // today unselected → red number
                  :                          Color(white: 0.75)      // normal → gray number
                )
                .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let spacerNum = config.offset
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let spacerNum = config.offset
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }

    private func dateToString(for date: Date) -> String {
        let symbols = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]
        let weekday = Calendar.current.component(.weekday, from: date)
        return symbols[weekday - 1]
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @State private var selectedDate = Date()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Button {
                    let scheme: String
                    switch Defaults[.calendarApp] {
                    case .fantastical:  scheme = "x-fantastical3://"
                    case .busyCal:      scheme = "busycal://"
                    case .notionCal:    scheme = "notion://"
                    case .apple:        scheme = "ical://"
                    }
                    if let url = URL(string: scheme) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    VStack(alignment: .leading) {
                        Text(selectedDate.formatted(.dateTime.month(.abbreviated)))
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        Text(selectedDate.formatted(.dateTime.year()))
                            .font(.title3)
                            .fontWeight(.light)
                            .foregroundColor(Color(white: 0.65))
                    }
                }
                .buttonStyle(CalendarHeaderButtonStyle())

                // Alpha-mask the edges instead of overlaying a black gradient — an
                // overlay paints opaque color on top (fine on solid black, but a
                // visible smear over liquid glass); a mask fades the picker's own
                // transparency, letting whatever's behind it show through instead.
                WheelPicker(selectedDate: $selectedDate, config: Config())
                    .frame(height: 52)
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 20)
                            Rectangle().fill(Color.black)
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: 20)
                        }
                    )
            }

            let filteredEvents = EventListView.filteredEvents(
                events: calendarManager.events
            )
            if filteredEvents.isEmpty {
                EmptyEventsView(selectedDate: selectedDate)
                Spacer(minLength: 0)
            } else {
                EventListView(events: calendarManager.events)
            }
        }
        .listRowBackground(Color.clear)
        .frame(height: 120)
        .onChange(of: selectedDate) {
            calendarManager.scheduleUpdate(for: selectedDate)
        }
        .onChange(of: vm.notchState) { _, _ in
            selectedDate = Date.now
            calendarManager.scheduleUpdate(for: Date.now)
        }
        .onAppear {
            selectedDate = Date.now
            calendarManager.scheduleUpdate(for: Date.now)
        }
    }
}

// MARK: - Compact Calendar

struct CompactCalendarView: View {
    @EnvironmentObject var vm: KnotchViewModel
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.compactCalendarShowMonthView) private var showMonthView
    @State private var selectedDate = Date()
    // Only fetched/shown when today's own events don't fill the agenda
    // column — see tomorrowColumn.
    @State private var tomorrowEvents: [EventModel] = []

    private func filterCompactEvents(_ events: [EventModel]) -> [EventModel] {
        EventListView.filteredEvents(events: events).filter { event in
            if event.type.isReminder && !Defaults[.compactShowReminders] {
                return false
            }
            if event.isAllDay && !Defaults[.compactShowAllDayEvents] {
                return false
            }
            if case .reminder(let completed) = event.type, completed {
                return false
            }
            if event.eventStatus == .ended && Calendar.current.isDateInToday(event.start) {
                return false
            }
            return true
        }
    }

    // The full-size calendar view keeps completed/ended events visible but
    // faded (CalendarEventRow/ReminderRow's own opacity handling) — with only
    // one event row's worth of room here, a faded-but-present item just wastes
    // that slot, so this hides them outright instead.
    private var filteredEvents: [EventModel] {
        filterCompactEvents(calendarManager.events)
    }

    private var allDayEvents: [EventModel] {
        filteredEvents.filter { $0.isAllDay }
    }

    private var timedEvents: [EventModel] {
        filteredEvents.filter { !$0.isAllDay }
    }

    private var tomorrowDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
    }

    private var tomorrowFilteredEvents: [EventModel] {
        filterCompactEvents(tomorrowEvents)
    }

    private var tomorrowAllDayEvents: [EventModel] {
        tomorrowFilteredEvents.filter { $0.isAllDay }
    }

    private var tomorrowTimedEvents: [EventModel] {
        tomorrowFilteredEvents.filter { !$0.isAllDay }
    }

    // Same notch-hugging pull-up the music view uses for its album art —
    // tucks the header and month label up alongside the physical cutout
    // instead of leaving a flat gap above them.
    private var pullUp: CGFloat {
        max(vm.effectiveClosedNotchHeight - 4, 20) - 2
    }

    // The header sits a bit lower than a full pull-up — leaves the same kind
    // of extra bottom space the grid needed the same treatment for.
    private var headerPullUp: CGFloat {
        pullUp - 7
    }

    // The grid sits a bit lower than the header — pulling it up by the exact
    // same amount looked too tight against the top edge.
    private var gridPullUp: CGFloat {
        pullUp - 9
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                header
                    .offset(y: -headerPullUp)
                    .padding(.bottom, -headerPullUp)
                eventsArea
                    .offset(y: showMonthView ? 0 : -7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if showMonthView {
                    MonthGridView(selectedDate: $selectedDate)
                        .offset(y: -gridPullUp)
                        .padding(.bottom, -gridPullUp)
                } else if needsTomorrowFallback {
                    // Today's own events don't fill this column — same
                    // weekday-line-height slot as the other branch below,
                    // but with an actual "TMRW" label in it (right-aligned,
                    // to read as a small callout rather than a real header)
                    // instead of reserving it invisibly.
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("TMRW")
                            .font(.system(size: 12, weight: .bold, design: .default))
                            .foregroundColor(Color(white: 0.45))
                        tomorrowColumn
                    }
                    .offset(y: -14)
                } else {
                    // Reserves an invisible copy of just the header's
                    // weekday line (not the day number below it), so the
                    // agenda's first event lands level with the date
                    // number itself rather than guessing a pixel offset.
                    VStack(alignment: .leading, spacing: 0) {
                        Text(selectedDate.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                            .font(.system(size: 12, weight: .bold, design: .default))
                            .hidden()
                        agendaColumn
                    }
                    .offset(y: -14)
                }
            }
            .frame(width: 148)
        }
        .padding(.horizontal, 20)
        .padding(.top, 1)
        .padding(.bottom, 10)
        // A hard height, not maxHeight — otherwise a day with more events
        // (more all-day pills, in particular) makes this view report a
        // taller natural size and the whole panel grows with it. Shared with
        // CompactMusicPlayerView so the panel is pinned to the exact same
        // size switching between the two, regardless of either's own content.
        // No .clipped() here (matching CompactMusicPlayerView) since the
        // pull-up above deliberately overflows above this frame's top edge.
        .frame(height: compactContentHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .onChange(of: selectedDate) {
            calendarManager.scheduleUpdate(for: selectedDate)
        }
        .onAppear {
            selectedDate = Date.now
            calendarManager.scheduleUpdate(for: Date.now)
        }
        // Fetched independently of today's own `calendarManager.events` —
        // only actually shown once needsTomorrowFallback is true, but
        // fetched ahead of that so it's already on hand rather than
        // flashing empty while the request is in flight.
        .task(id: "\(selectedDate.timeIntervalSince1970)|\(showMonthView)") {
            guard !showMonthView else { return }
            tomorrowEvents = await calendarManager.fetchDayEvents(for: tomorrowDate)
        }
    }

    private var header: some View {
        Button {
            let scheme: String
            switch Defaults[.calendarApp] {
            case .fantastical:  scheme = "x-fantastical3://"
            case .busyCal:      scheme = "busycal://"
            case .notionCal:    scheme = "notion://"
            case .apple:        scheme = "ical://"
            }
            if let url = URL(string: scheme) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(selectedDate.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 12, weight: .bold, design: .default))
                    .foregroundColor(.red)
                    // Forces a fresh view (rather than an in-place text update)
                    // whenever the weekday changes, so the scale/opacity
                    // transition below actually has something to animate.
                    .id(selectedDate.formatted(.dateTime.weekday(.abbreviated)))
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: selectedDate)
                Text("\(Calendar.current.component(.day, from: selectedDate))")
                    .font(.system(size: 30, weight: .light, design: .default))
                    .foregroundColor(.white)
                    .contentTransition(.numericText(value: Double(Calendar.current.component(.day, from: selectedDate))))
                    .animation(.snappy(duration: 0.35), value: selectedDate)
            }
        }
        .buttonStyle(.plain)
    }

    // Always shown individually up to these caps, with anything beyond them
    // summarized in the overflow row — not "show everything if the whole
    // day happens to fit," just a fixed budget that's safe against clipping
    // regardless of how many events the day actually has.
    private let maxAllDayPills = 1
    private let maxVisibleTimedEvents = 2

    // The agenda column (right side, month view off) doesn't use a flat
    // cap like the two above — its rows are a fixed height, so instead this
    // fills as much of its own vertical budget as actually fits. Tune
    // agendaColumnBudget if it over/undershoots visually — CalendarEventRow
    // and the VStack spacing in agendaColumn are what agendaRowHeight/
    // agendaRowSpacing need to keep matching.
    private let agendaColumnBudget: CGFloat = 100
    private let agendaRowHeight: CGFloat = 30
    private let agendaRowSpacing: CGFloat = 4
    private var maxAgendaEvents: Int {
        max(0, Int((agendaColumnBudget + agendaRowSpacing) / (agendaRowHeight + agendaRowSpacing)))
    }

    // With more than one all-day event, a single pill can only ever show one
    // of them — swap to the icon-stack summary row instead so nothing is
    // silently hidden, and none of the all-day events then need to fall
    // through to the generic overflow row below.
    private var showAllDaySummary: Bool { allDayEvents.count > maxAllDayPills }

    // With the month grid on the right, an all-day pill/summary row already
    // claims one of the budgeted rows above the timed list, so only 1 timed
    // event (not the usual 2) fits underneath it without clipping — the
    // grid's own height sets that budget. The agenda column doesn't share
    // that constraint, so the left side keeps its full budget regardless of
    // an all-day pill.
    private var visibleTimedEventCount: Int {
        guard showMonthView, !allDayEvents.isEmpty else { return maxVisibleTimedEvents }
        return 1
    }
    private var visibleTimedEvents: [EventModel] { Array(timedEvents.prefix(visibleTimedEventCount)) }

    // Only populated with month view off — the events that would otherwise
    // sit behind the "N more" overflow row, shown instead as full rows in
    // the space the month grid isn't using.
    private var agendaEvents: [EventModel] {
        guard !showMonthView else { return [] }
        return Array(timedEvents.dropFirst(visibleTimedEvents.count).prefix(maxAgendaEvents))
    }

    private var hiddenEvents: [EventModel] {
        Array(showAllDaySummary ? [] : allDayEvents.dropFirst(min(allDayEvents.count, maxAllDayPills)))
            + Array(timedEvents.dropFirst(visibleTimedEvents.count + agendaEvents.count))
    }

    // Whether today has nothing left over for the agenda column, meaning
    // it should fall back to showing tomorrow's events instead of sitting
    // empty. maxAgendaEvents is never 0 in practice, so agendaEvents being
    // empty already implies there's no overflow left either.
    private var needsTomorrowFallback: Bool {
        !showMonthView && agendaEvents.isEmpty
    }

    private var tomorrowShowAllDaySummary: Bool { tomorrowAllDayEvents.count > maxAllDayPills }

    // Mirrors visibleTimedEventCount/visibleTimedEvents, but the tomorrow
    // column has no separate left/right split to share the budget with —
    // an all-day pill/summary here claims one of its own rows directly.
    private var tomorrowVisibleTimedCount: Int {
        max(0, maxAgendaEvents - (tomorrowAllDayEvents.isEmpty ? 0 : 1))
    }
    private var tomorrowVisibleTimedEvents: [EventModel] {
        Array(tomorrowTimedEvents.prefix(tomorrowVisibleTimedCount))
    }

    private var tomorrowHiddenEvents: [EventModel] {
        Array(tomorrowShowAllDaySummary ? [] : tomorrowAllDayEvents.dropFirst(min(tomorrowAllDayEvents.count, maxAllDayPills)))
            + Array(tomorrowTimedEvents.dropFirst(tomorrowVisibleTimedEvents.count))
    }

    // All-day events are pinned above the timed list, rendered small as
    // pills rather than full event rows.
    private var pillTransition: AnyTransition {
        .opacity.combined(with: .blur(radius: 4))
    }

    @ViewBuilder
    private var eventsArea: some View {
        if allDayEvents.isEmpty && timedEvents.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if showAllDaySummary {
                    Button {
                        if let firstAllDay = allDayEvents.first, let url = firstAllDay.calendarAppURL() {
                            openURL(url)
                        }
                    } label: {
                        CompactAllDaySummaryRow(events: allDayEvents)
                    }
                    .buttonStyle(OpacityReactiveButtonStyle())
                    .id(selectedDate)
                    .transition(pillTransition)
                } else {
                    ForEach(allDayEvents.prefix(maxAllDayPills)) { event in
                        Button {
                            if let url = event.calendarAppURL() { openURL(url) }
                        } label: {
                            CompactAllDayPill(event: event)
                        }
                        .buttonStyle(EventRowButtonStyle(color: Color(event.calendar.color), isCapsule: true))
                        .transition(pillTransition)
                    }
                }
                ForEach(visibleTimedEvents) { event in
                    Button {
                        if let url = event.calendarAppURL() { openURL(url) }
                    } label: {
                        if case .reminder(let completed) = event.type {
                            ReminderRow(event: event, isCompleted: completed, showFullTitle: false, compactSizing: true)
                        } else {
                            CalendarEventRow(event: event, showFullTitle: false, compactSizing: true)
                        }
                    }
                    .buttonStyle(EventRowButtonStyle(color: Color(event.calendar.color)))
                    // Same day, different event (e.g. after switching from a
                    // day with no timed events) — this id forces a fresh view
                    // so the transition actually fires instead of the Button
                    // just updating its label content in place.
                    .id(event.id)
                    .transition(pillTransition)
                }
                // In agenda mode this instead renders at the end of the
                // agenda column, after the continuation events on the
                // right, rather than here right after the left column's own
                // — see agendaColumn.
                if !hiddenEvents.isEmpty && showMonthView {
                    CompactMoreEventsRow(events: Array(hiddenEvents))
                        .id(selectedDate)
                        .transition(pillTransition)
                }
            }
            // calendarManager.events arrives asynchronously from
            // CalendarManager.scheduleUpdate (a detached Task) well after the
            // withAnimation block around the day tap has already ended, so
            // the pills' insert/remove transitions above never had an active
            // animation to run inside. This re-wraps that later, unrelated
            // update in its own animation.
            .animation(.easeInOut(duration: 0.4), value: calendarManager.events)
        }
    }

    // Stands in for MonthGridView when month view is off — fills the same
    // slot with more of the day's events, in the exact same fixed-height
    // compactSizing rows as the left column, so this column's height is
    // just as predictable and never grows the overall view regardless of
    // event count.
    @ViewBuilder
    private var agendaColumn: some View {
        if !agendaEvents.isEmpty || !hiddenEvents.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(agendaEvents) { event in
                    Button {
                        if let url = event.calendarAppURL() { openURL(url) }
                    } label: {
                        if case .reminder(let completed) = event.type {
                            ReminderRow(event: event, isCompleted: completed, showFullTitle: false, compactSizing: true)
                        } else {
                            CalendarEventRow(event: event, showFullTitle: false, compactSizing: true)
                        }
                    }
                    .buttonStyle(EventRowButtonStyle(color: Color(event.calendar.color)))
                    .id(event.id)
                    .transition(pillTransition)
                }
                // The continuation's own overflow indicator — sits after
                // the last event shown on either side, not the left
                // column's own (see eventsArea).
                if !hiddenEvents.isEmpty {
                    CompactMoreEventsRow(events: Array(hiddenEvents))
                        .id(selectedDate)
                        .transition(pillTransition)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: calendarManager.events)
        }
    }

    // Shown in the agenda column's slot instead of agendaColumn once
    // today's own events run out — same all-day-pill-then-compact-rows
    // shape as the left column's eventsArea, just sourced from
    // tomorrowFilteredEvents instead of today's.
    @ViewBuilder
    private var tomorrowColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if tomorrowShowAllDaySummary {
                Button {
                    if let firstAllDay = tomorrowAllDayEvents.first, let url = firstAllDay.calendarAppURL() {
                        openURL(url)
                    }
                } label: {
                    CompactAllDaySummaryRow(events: tomorrowAllDayEvents)
                }
                .buttonStyle(OpacityReactiveButtonStyle())
            } else {
                ForEach(tomorrowAllDayEvents.prefix(maxAllDayPills)) { event in
                    Button {
                        if let url = event.calendarAppURL() { openURL(url) }
                    } label: {
                        CompactAllDayPill(event: event)
                    }
                    .buttonStyle(EventRowButtonStyle(color: Color(event.calendar.color), isCapsule: true))
                }
            }
            ForEach(tomorrowVisibleTimedEvents) { event in
                Button {
                    if let url = event.calendarAppURL() { openURL(url) }
                } label: {
                    if case .reminder(let completed) = event.type {
                        ReminderRow(event: event, isCompleted: completed, showFullTitle: false, compactSizing: true)
                    } else {
                        CalendarEventRow(event: event, showFullTitle: false, compactSizing: true)
                    }
                }
                .buttonStyle(EventRowButtonStyle(color: Color(event.calendar.color)))
                .id(event.id)
            }
            if !tomorrowHiddenEvents.isEmpty {
                CompactMoreEventsRow(events: tomorrowHiddenEvents)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Calendar.current.isDateInToday(selectedDate) ? "No more events today" : "No events")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundColor(.white.opacity(0.85))
            Text(Calendar.current.isDateInToday(selectedDate) ? "Your day is clear" : "This day is clear")
                .font(.system(size: 12, weight: .regular, design: .default))
                .foregroundColor(.secondary)
        }
    }
}

private struct CompactAllDayPill: View {
    let event: EventModel
    @Environment(\.eventRowPressed) private var isPressed

    private var calColor: Color { isPressed ? .black : Color(event.calendar.color) }
    // Same dark tint as the pill's own background fill at rest, flips to
    // black alongside the text/circle-adjacent content when pressed.
    private var glyphColor: Color {
        isPressed ? .black : Color(event.calendar.color).opaqueDarkTint(alpha: 0.12)
    }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: event.type.iconName)
                .font(.system(size: 8, weight: .semibold, design: .default))
                .foregroundColor(glyphColor)
                .frame(width: 14, height: 14)
                .background {
                    // The exact same tint the pill itself shows when
                    // pressed, instead of the plain solid calendar color.
                    if isPressed {
                        pillPressTint(Color(event.calendar.color))
                    } else {
                        Color(event.calendar.color)
                    }
                }
                .clipShape(Circle())
            Text(event.title)
                .font(.system(size: 10, weight: .medium, design: .default))
                // Tinted with the calendar color, same as CalendarEventRow's
                // title, instead of plain white.
                .foregroundColor(calColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        // Same background dimness as CalendarEventRow's normal events, not
        // its own separate, more-visible tint.
        .background(Color(event.calendar.color).opacity(0.12))
        .clipShape(Capsule())
        // Bounds the title's width so an unusually long one truncates with
        // "…" instead of just growing the pill to fit.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Shown instead of CompactAllDayPill when there's more than one all-day
// event — a single pill can only represent one of them, so this stacks each
// event's own icon badge (same look as CompactAllDayPill's) instead of
// picking a single event to show and silently dropping the rest.
private struct CompactAllDaySummaryRow: View {
    let events: [EventModel]
    private let maxIcons = 3

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: -6) {
                ForEach(Array(events.prefix(maxIcons).enumerated()), id: \.offset) { index, event in
                    Image(systemName: event.type.iconName)
                        .font(.system(size: 8, weight: .semibold, design: .default))
                        .foregroundColor(Color(event.calendar.color).opaqueDarkTint(alpha: 0.12))
                        .frame(width: 14, height: 14)
                        .background(Color(event.calendar.color))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5))
                        .zIndex(Double(maxIcons - index))
                }
            }
            Text("\(events.count) all-day event\(events.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundColor(.secondary)
        }
    }
}

// Bar colors and count reflect the actual remaining events, not a placeholder.
private struct CompactMoreEventsRow: View {
    let events: [EventModel]
    private let maxBars = 2

    // One bar per distinct calendar color, not one per event — several same-
    // colored events in a row shouldn't draw duplicate bars.
    private var barColors: [Color] {
        var seen: [NSColor] = []
        for event in events {
            let color = event.calendar.color
            if !seen.contains(color) {
                seen.append(color)
                if seen.count == maxBars { break }
            }
        }
        return seen.map(Color.init)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Matches CalendarEventRow's own bar leading padding, so this
            // row's bar lines up with the ones on the event rows above it.
            HStack(spacing: 2) {
                ForEach(Array(barColors.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color)
                        .frame(width: 3, height: 12)
                }
            }
            .padding(.leading, 4)
            Text("\(events.count) more event\(events.count == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundColor(.secondary)
        }
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date

    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(Color(white: 0.65))
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.white)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(Color(white: 0.65))
        }
    }
}
// MARK: - Row Views

private struct ReminderRow: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    let event: EventModel
    let isCompleted: Bool
    let showFullTitle: Bool
    var compactSizing: Bool = false

    var body: some View {
        HStack(spacing: compactSizing ? 6 : 8) {
            ReminderToggle(
                isOn: Binding(
                    get: { isCompleted },
                    set: { newValue in
                        Task {
                            await calendarManager.setReminderCompleted(
                                reminderID: event.id, completed: newValue
                            )
                        }
                    }
                ),
                color: Color(event.calendar.color),
                size: compactSizing ? 11 : 14
            )
            .opacity(1.0)
            HStack {
                Text(event.title)
                    .font(compactSizing ? .caption : .callout)
                    .foregroundColor(.white)
                    .lineLimit(showFullTitle ? nil : 1)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if event.isAllDay {
                        Text("All-day")
                            .font(compactSizing ? .caption2 : .caption)
                            .fontWeight(.medium)
                            .foregroundColor(Color(white: 0.6))
                            .lineLimit(1)
                    } else {
                        Text(event.start, style: .time)
                            .foregroundColor(Color(white: 0.6))
                            .font(compactSizing ? .caption2 : .caption)
                    }
                }
            }
            .opacity(
                isCompleted
                    ? 0.4
                    : event.start < Date.now && Calendar.current.isDateInToday(event.start)
                        ? 0.6 : 1.0
            )
        }
        .padding(.vertical, 4)
    }
}

private struct CalendarEventRow: View {
    let event: EventModel
    let showFullTitle: Bool
    // Forces a single-line title and hides the location row, so every
    // instance renders at the exact same fixed height regardless of content
    // — matching CompactAllDayPill's always-one-line sizing. Off by default
    // so the full-size CalendarView keeps wrapping long titles as before.
    var compactSizing: Bool = false
    @Environment(\.eventRowPressed) private var isPressed

    // "9:00am - 9:45am" — no space before am/pm.
    private static let compactTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f
    }()

    private var compactTimeRangeText: String {
        let start = Self.compactTimeFormatter.string(from: event.start)
        let end = Self.compactTimeFormatter.string(from: event.end)
        return "\(start) - \(end)"
    }

    var body: some View {
        let calColor: Color = isPressed ? .black : Color(event.calendar.color)

        HStack(alignment: .center, spacing: 0) {
            // Colored left border
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(event.calendar.color))
                .frame(width: 3)
                .padding(.vertical, 4)
                .padding(.leading, 4)

            if compactSizing {
                // Time sits on its own line under the title instead of a
                // trailing column, so every row is exactly title + time —
                // two fixed lines regardless of what's in either of them.
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(calColor)
                        .lineLimit(1)
                    Text(event.isAllDay ? "All-day" : compactTimeRangeText)
                        .font(.caption2)
                        .foregroundColor(calColor.opacity(0.8))
                        .lineLimit(1)
                }
                // Without this, an unusually long title has nothing bounding
                // its width, so lineLimit(1) never gets a chance to truncate
                // it — the row just grows to fit instead.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
            } else {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(calColor)
                            .lineLimit(showFullTitle ? nil : 2)

                        if let location = event.location, !location.isEmpty {
                            HStack(spacing: 3) {
                                MapPinIcon(color: calColor)
                                    .frame(width: 10, height: 10)
                                Text(location)
                                    .font(.system(size: 10))
                                    .foregroundColor(calColor.opacity(0.9))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        if event.isAllDay {
                            Text("All-day")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(calColor)
                                .lineLimit(1)
                        } else {
                            Text(event.start, style: .time)
                                .foregroundColor(calColor)
                            Text(event.end, style: .time)
                                .foregroundColor(calColor.opacity(0.75))
                        }
                    }
                    .font(.caption2)
                    .frame(minWidth: 44, alignment: .trailing)
                }
                .padding(.leading, 8)
                .padding(.trailing, 10)
                .padding(.vertical, 3)
            }
        }
        // Belt-and-suspenders on top of the fixed 2-line content above:
        // an explicit height guarantees every compact row is pixel-identical
        // regardless of any remaining text-metric variance between events.
        .frame(height: compactSizing ? 30 : nil)
        .background(
            Color(event.calendar.color).opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .opacity(
            event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
                ? 0.6 : 1.0
        )
    }
}

private struct MapPinIcon: View {
    let color: Color

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let cx = size.width / 2
                let r = size.width * 0.36
                let tipY = size.height
                let baseY = size.height * 0.52
                let baseHalf = size.width * 0.38
                let holeR = r * 0.45

                // Outer pin shape as one unified path
                var pin = Path()
                pin.addEllipse(in: CGRect(x: cx - r, y: 0, width: r * 2, height: r * 2))
                pin.move(to: CGPoint(x: cx - baseHalf * 0.75, y: baseY))
                pin.addLine(to: CGPoint(x: cx + baseHalf * 0.75, y: baseY))
                pin.addLine(to: CGPoint(x: cx, y: tipY))
                pin.closeSubpath()
                context.fill(pin, with: .color(color))

                // Punch hole using blendMode
                var hole = Path()
                hole.addEllipse(in: CGRect(x: cx - holeR, y: r - holeR, width: holeR * 2, height: holeR * 2))
                context.blendMode = .clear
                context.fill(hole, with: .color(.black))
            }
            .compositingGroup()
        }
    }
}

// MARK: - EventListView

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles

    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder {
                if case .reminder(let completed) = event.type {
                    return !completed || !Defaults[.hideCompletedReminders]
                }
            }
            if event.isAllDay && Defaults[.hideAllDayEvents] {
                return false
            }
            return true
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        let now = Date()
        let nonAllDayUpcoming = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = filteredEvents.first(where: { $0.isAllDay })
        let lastEvent = filteredEvents.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(filteredEvents) { event in
                        Button {
                            if let url = event.calendarAppURL() { openURL(url) }
                        } label: {
                            if case .reminder(let completed) = event.type {
                                ReminderRow(
                                    event: event,
                                    isCompleted: completed,
                                    showFullTitle: showFullEventTitles
                                )
                            } else {
                                CalendarEventRow(
                                    event: event,
                                    showFullTitle: showFullEventTitles
                                )
                            }
                        }
                        .buttonStyle(EventRowButtonStyle(color: Color(event.calendar.color)))
                        .padding(.vertical, 1)
                        .id(event.id)
                    }
                }
                // Keeps the first/last row's content clear of the fade zone below,
                // instead of the fade cutting straight across the row itself.
                .padding(.vertical, 2.5)
            }
            .scrollIndicators(.never)
            // Small, subtle edge fade — kept short relative to row height so
            // it reads as a soft scroll-edge hint, not the wheel picker's
            // pronounced curved/drum look.
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 6)
                    Rectangle().fill(Color.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 6)
                }
            )
            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
        Spacer(minLength: 0)
    }
}

private struct EventRowButtonStyle: ButtonStyle {
    let color: Color
    // CompactAllDayPill is a capsule, not a rounded rect — matches its own
    // clipShape so the press highlight doesn't peek out past the pill's edges.
    var isCapsule: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.eventRowPressed, configuration.isPressed)
            .background {
                if configuration.isPressed {
                    pillPressTint(color)
                } else {
                    Color.clear
                }
            }
            .clipShape(isCapsule ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// The classic dim-on-press feedback, no colored background — used where a
// calendar-color highlight wouldn't make sense (e.g. a row standing in for
// several events, each with a different calendar color).
private struct OpacityReactiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct EventRowPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var eventRowPressed: Bool {
        get { self[EventRowPressedKey.self] }
        set { self[EventRowPressedKey.self] = newValue }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color
    var size: CGFloat = 14

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: size * (2.0 / 14.0))
                    .frame(width: size, height: size)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: size * (8.0 / 14.0), height: size * (8.0 / 14.0))
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: size, height: size)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

private struct CalendarHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(KnotchViewModel())
}
