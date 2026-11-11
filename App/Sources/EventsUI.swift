import BelfryCore
import SwiftUI

// Events (SPEC 19.8 older sessions, 19.18 Belfry events): the event's page and All events.

struct EventPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let key: String

    var body: some View {
        let _ = model.version
        let d = model.derive
        NavigationStack {
            if let e = d.eventByKey(key) {
                EventPageBody(e: e) { dismiss(); openChannel(e.groupId, nil) }
                    .navigationTitle(e.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            } else {
                ContentUnavailableView("There is no such event here.", systemImage: "calendar.badge.exclamationmark")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
        .presentationDetents([.large])
    }
}

struct EventPageBody: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let openChat: () -> Void

    var body: some View {
        let d = model.derive
        let now = Int.now
        let state = d.myState(e)
        List {
            Section {
                if let c = e.cover, let u = URL(string: c), c.hasPrefix("https://") {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                        .frame(height: 160).clipped().listRowInsets(EdgeInsets())
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(e.title).font(.title2.bold())
                    if e.status == .cancelled {
                        Label("Cancelled" + (e.statusReason.map { ": " + $0 } ?? ""), systemImage: "xmark.octagon").foregroundStyle(.red)
                    } else if d.stillGoing(e) {
                        Label("Changed since you answered. Still going?", systemImage: "exclamationmark.circle").foregroundStyle(Color.bronze)
                    } else if let l = state.line {
                        Text(l).font(.subheadline.weight(.semibold)).foregroundStyle(Color.bronze)
                    }
                }
            }
            Section {
                Label(d.lineDay(e.start, now: now) + " · " + d.lineWhen(e), systemImage: "calendar")
                if let l = e.location, !l.isEmpty { Label(l, systemImage: "mappin.and.ellipse") }
                ForEach(e.links, id: \.self) { l in
                    if let u = URL(string: l) { Link(destination: u) { Label(Actions.meetingLabel(l), systemImage: "video") } }
                }
                if e.isNew { Label("\(e.going) going", systemImage: "person.2") }
            }
            if d.isOpen(e, now: now) {
                Section("Your answer") {
                    HStack {
                        ForEach(Rsvp.allCases, id: \.self) { r in
                            if d.myRsvp(e) == r {
                                BusyButton(r.label) { model.rsvp(e, r) }.buttonStyle(.borderedProminent)
                            } else {
                                BusyButton(r.label) { model.rsvp(e, r) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if !e.description.isEmpty { Section("About") { MarkdownText(text: e.description) } }
            Section {
                Button(action: openChat) { ActionRow(icon: "bubble.left.and.bubble.right", title: "The event's chat") }
                if e.isNew {
                    let url = d.eventURL(e)
                    if let u = URL(string: url) {
                        ShareLink(item: u) { ActionRow(icon: "square.and.arrow.up", title: "Share the event's address", detail: url) }
                    }
                }
            }
        }
    }
}

struct EventsList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String?
    @State private var tab: EventsTab = .upcoming

    var body: some View {
        let d = model.derive
        let list = d.eventsIn(tab, now: .now, channel: channel)
        NavigationStack {
            List {
                Picker("Show", selection: $tab) {
                    ForEach(EventsTab.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if list.isEmpty { Text(tab.empty).foregroundStyle(.secondary) }
                ForEach(list) { e in
                    Button { model.openEvent = e.coord } label: { EventRow(e: e) }.buttonStyle(.plain)
                }
            }
            .navigationTitle(channel.flatMap { model.group($0)?.name }.map { "Events in \($0)" } ?? "All events")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct EventRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        let d = model.derive
        HStack(spacing: 10) {
            DateChip(at: e.start)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(d.lineDay(e.start, now: .now) + " · " + d.lineWhen(e)).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if e.status == .cancelled { Chip(text: "Cancelled", tint: .red) }
                    Text([d.stateLabel(e), e.going > 0 ? "\(e.going) going" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
