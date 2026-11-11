import BelfryCore
import PhotosUI
import SwiftUI

// Belfry events (SPEC 19.18) and the older sessions (19.8): the event's page (the one line,
// when / where / online, my answer, tickets, hosts, description, URL, guest list, the chat),
// the event form (make / edit, cover, all day, where, online + Jitsi, who sees it, who can
// come, the URL checked as typed), tickets, co-host link, All events.

struct EventPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let key: String
    @State private var remote: ApiEvent?
    @State private var error: String?

    var body: some View {
        let _ = model.version
        let d = model.derive
        NavigationStack {
            SwiftUI.Group {
                if let e = d.eventByKey(key) {
                    EventPageBody(e: e, api: nil) { dismiss(); openChannel(e.groupId, nil) }
                } else if let r = remote {
                    EventPageBody(e: r.calEvent(timeZone: .current, me: model.me), api: r) { dismiss(); openChannel(r.group, nil) }
                } else if let error {
                    ContentUnavailableView(error, systemImage: "calendar.badge.exclamationmark")
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                guard d.eventByKey(key) == nil else { return }
                switch await model.remoteEvent(key) {
                case .success(let r): remote = r
                case .failure(let e): error = e.message
                }
            }
        }
        .presentationDetents([.large])
    }
}

struct EventPageBody: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let api: ApiEvent?
    let openChat: () -> Void
    @State private var applying: Ticket?
    @State private var editing = false
    @State private var tickets = false
    @State private var cancel = false
    @State private var confirmDelete = false
    @State private var coHost: String?
    @State private var error: String?

    var body: some View {
        let d = model.derive
        let now = Int.now
        let people = d.eventPeople(e)
        let state = api?.myState ?? d.myState(e, people)
        let host = d.isHost(e)
        let list = api.map { $0.tickets.map(\.ticket) } ?? d.tickets(e)
        let ticketList = list.isEmpty ? [EventLinks.freeTicket(e.d)] : list
        List {
            Section {
                if let c = e.cover, let u = URL(string: c), c.hasPrefix("https://") {
                    AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.1) }
                        .frame(height: 170).clipped().listRowInsets(EdgeInsets())
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(e.title).font(.title2.bold())
                    EventLine(e: e, state: state, people: people, host: host)
                }
            }
            Section {
                Label(d.lineDay(e.start, now: now) + " · " + d.lineWhen(e), systemImage: "calendar")
                if let l = e.location, !l.isEmpty { Label(l, systemImage: "mappin.and.ellipse") }
                if e.links.isEmpty && (api?.online ?? false) {
                    Label("The online link shows once you have a place", systemImage: "video").foregroundStyle(.secondary)
                }
                ForEach(e.links, id: \.self) { l in
                    if let u = URL(string: l) { Link(destination: u) { Label("Join on \(Actions.meetingLabel(l))", systemImage: "video") } }
                }
                if e.isNew { Label("\(e.going) going", systemImage: "person.2") }
            }
            if d.isOpen(e, now: now) && !host {
                Section("Your place") {
                    switch state {
                    case .applied, .waitlist:
                        Text(state.line ?? "").font(.subheadline)
                        if let a = people.applications.first(where: { $0.pubkey == model.me }), !a.answer.isEmpty {
                            Text("“\(a.answer)”").font(.caption).foregroundStyle(.secondary)
                        }
                        BusyButton("Withdraw", role: .destructive) { model.withdraw(e) }
                    case .declined:
                        Text(state.line ?? "").font(.subheadline)
                    default:
                        if ticketList.count == 1 && ticketList[0].implicit {
                            RsvpButtons(e: e)
                        } else {
                            if d.myRsvp(e) != nil || people.holders[model.me] != nil { RsvpButtons(e: e) }
                            ForEach(ticketList) { t in TicketRow(e: e, t: t, people: people, held: people.holders[model.me] == t.d) { applying = t } }
                        }
                    }
                    if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
            }
            if !e.hosts.isEmpty {
                Section("Hosts") {
                    ForEach(Array(e.hosts).sorted(), id: \.self) { pk in
                        Button { model.openProfile = pk } label: {
                            HStack { Avatar(pubkey: pk, size: 26); Text(api?.hosts.first { $0.first == pk }?.last.flatMap { $0.isEmpty ? nil : $0 } ?? model.name(pk)) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !e.description.isEmpty { Section("About") { MarkdownText(text: e.description) } }
            if e.isNew {
                Section("Address") { LinkBlock(url: d.eventURL(e), title: e.title, message: e.title) }
            }
            if host && e.isNew && !e.remote { GuestList(e: e, people: people) }
            Section {
                Button(action: openChat) { ActionRow(icon: "bubble.left.and.bubble.right", title: "The event's chat") }
                if host && e.isNew {
                    Button { editing = true } label: { ActionRow(icon: "pencil", title: "Edit the event") }
                    Button { tickets = true } label: { ActionRow(icon: "ticket", title: "Tickets", detail: "\(list.filter { !$0.implicit }.count) defined") }
                    ActionButtonRow(icon: "person.badge.plus", title: "Co-host link", detail: coHost ?? "For one person, for a day") {
                        switch await model.coHostLink(e) {
                        case .success(let u): coHost = u; UIPasteboard.general.string = u
                        case .failure(let x): error = x.message
                        }
                    }
                    if e.status == .cancelled {
                        ActionButtonRow(icon: "arrow.uturn.backward", title: "Reopen the event") { model.setEventStatus(e, .scheduled) }
                    } else {
                        Button { cancel = true } label: { ActionRow(icon: "xmark.octagon", title: "Cancel the event", destructive: true) }
                    }
                }
                if e.creator == model.me {
                    Button { confirmDelete = true } label: { ActionRow(icon: "trash", title: "Delete the event", destructive: true) }
                }
            }
        }
        .navigationTitle(e.title)
        .sheet(item: $applying) { t in ApplySheet(e: e, t: t, full: (people.placesLeft(t) ?? 1) <= 0) }
        .sheet(isPresented: $editing) { EventFormSheet(editing: e, channel: nil) }
        .sheet(isPresented: $tickets) { TicketsSheet(e: e) }
        .sheet(isPresented: $cancel) { CancelEventSheet(e: e) }
        .confirmationDialog("Delete this event?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteEvent(e) }
        } message: { Text("It disappears for everyone. This can't be undone.") }
    }
}

/// The event's one line: cancelled / changed · still going? / people asking / my state.
struct EventLine: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let state: MyState
    let people: EventPeople
    let host: Bool
    var body: some View {
        let d = model.derive
        if e.status == .cancelled {
            Label("Cancelled" + (e.statusReason.map { ": " + $0 } ?? ""), systemImage: "xmark.octagon").foregroundStyle(.red)
        } else if d.stillGoing(e) {
            HStack {
                Text("Changed · still going?").font(.subheadline.weight(.semibold)).foregroundStyle(Color.bronze)
                BusyButton("Yes") { model.rsvp(e, .accepted) }.buttonStyle(.borderedProminent)
                BusyButton("No") { model.rsvp(e, .declined) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        } else if host && !people.applications.isEmpty {
            Text("\(people.applications.count) \(people.applications.count == 1 ? "person asks" : "people ask") for a place").font(.subheadline.weight(.semibold)).foregroundStyle(Color.bronze)
        } else if host {
            Text("You're hosting").font(.subheadline.weight(.semibold)).foregroundStyle(Color.bronze)
        } else if let l = state.line {
            Text(l).font(.subheadline.weight(.semibold)).foregroundStyle(Color.bronze)
        }
    }
}

struct RsvpButtons: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        let mine = model.derive.myRsvp(e)
        HStack {
            ForEach(Rsvp.allCases, id: \.self) { r in
                if mine == r {
                    BusyButton(r.label) { model.rsvp(e, r) }.buttonStyle(.borderedProminent)
                } else {
                    BusyButton(r.label) { model.rsvp(e, r) }.buttonStyle(.bordered)
                }
            }
        }
        .controlSize(.small)
    }
}

struct TicketRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let t: Ticket
    let people: EventPeople
    let held: Bool
    let apply: () -> Void
    @State private var error: String?
    var body: some View {
        let left = people.placesLeft(t)
        let guestBlocked = t.members && model.derive.amGuest
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.subheadline.weight(.semibold))
                    let bits = [t.summary.isEmpty ? nil : t.summary, left.map { $0 == 0 ? "Full" : "\($0) left" }, t.members ? "Members only" : nil, t.closed ? "By application" : nil].compactMap { $0 }
                    if !bits.isEmpty { Text(bits.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if held {
                    Chip(text: "Yours", tint: .green)
                } else if guestBlocked {
                    Text("Members only").font(.caption).foregroundStyle(.secondary)
                } else if t.closed || (left ?? 1) <= 0 {
                    Button((left ?? 1) <= 0 ? "Waitlist" : "Apply", action: apply).buttonStyle(.bordered).controlSize(.small)
                } else {
                    BusyButton("Take it") { error = await model.takeTicket(e, t) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// An application (or a place on the waitlist), with the ticket's question.
struct ApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    let t: Ticket
    let full: Bool
    @State private var answer = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(t.prompt.isEmpty ? "Why would you like to come?" : t.prompt).font(.headline)
                    TextField("Your answer", text: $answer, axis: .vertical).lineLimit(3...8).font(.body)
                } footer: { Text(full ? "This ticket is full: you join the waitlist and the hosts tell you." : "The hosts read your answer and give you a place.") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle(full ? "Join the waitlist" : "Apply for \(t.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Send") {
                        if let x = await model.applyTicket(e, t, answer: answer.jsTrim(), waitlist: full) { error = x } else { dismiss() }
                    }
                    .disabled(answer.jsTrim().isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Hosts: Going / Asking / Waitlist / Others, approve / decline, make co-host.
struct GuestList: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let people: EventPeople
    @State private var error: String?
    var body: some View {
        let asking = people.applications.filter { !$0.waitlist }
        let waiting = people.applications.filter(\.waitlist)
        let going = e.goingKeys
        let others = e.rsvps.filter { $0.value != .accepted }.keys.sorted()
        if !asking.isEmpty { Section("Asking (\(asking.count))") { ForEach(asking, id: \.pubkey) { a in appRow(a) } } }
        if !waiting.isEmpty { Section("Waitlist (\(waiting.count))") { ForEach(waiting, id: \.pubkey) { a in appRow(a) } } }
        Section("Going (\(going.count))") {
            if going.isEmpty { Text("Nobody yet.").foregroundStyle(.secondary) }
            ForEach(going, id: \.self) { pk in
                HStack {
                    Avatar(pubkey: pk, size: 26)
                    Text(model.name(pk))
                    Spacer()
                    if !e.hosts.contains(pk) {
                        Menu {
                            Button("Make co-host") { model.addCoHost(e, pk) }
                            Button("Take the place back", role: .destructive) { Task { error = await model.decide(e, pk, approve: false, ticket: nil, application: nil) } }
                        } label: { Image(systemName: "ellipsis.circle") }
                    } else { Chip(text: "host") }
                }
            }
        }
        if !others.isEmpty {
            Section("Others") {
                ForEach(others, id: \.self) { pk in HStack { Avatar(pubkey: pk, size: 26); Text(model.name(pk)); Spacer(); Text(e.rsvps[pk]?.label ?? "").font(.caption).foregroundStyle(.secondary) } }
            }
        }
        if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
    }

    func appRow(_ a: EventApplication) -> some View {
        DecideRow(e: e, a: a) { error = $0 }
    }
}

/// One application: Approve and Decline share one lock.
struct DecideRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    let a: EventApplication
    let report: (String?) -> Void
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Avatar(pubkey: a.pubkey, size: 26); Text(model.name(a.pubkey)).font(.subheadline.weight(.semibold)); if busy { ProgressView().controlSize(.small) } }
            if !a.answer.isEmpty { Text(a.answer).font(.subheadline).foregroundStyle(.secondary) }
            HStack {
                Button("Approve") { go(true) }.buttonStyle(.borderedProminent)
                Button("Decline", role: .destructive) { go(false) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(busy)
        }
    }
    func go(_ approve: Bool) {
        guard !busy else { return }
        busy = true
        Task {
            report(await model.decide(e, a.pubkey, approve: approve, ticket: a.ticket, application: a.ev))
            busy = false
        }
    }
}

struct CancelEventSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State private var reason = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A line for the guests (optional)", text: $reason, axis: .vertical).lineLimit(2...5).font(.body)
                } footer: { Text("Everyone who answered sees that it is cancelled. You can reopen it.") }
            }
            .navigationTitle("Cancel \(e.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Cancel the event", role: .destructive) { model.setEventStatus(e, .cancelled, reason: reason.jsTrim()); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Make or edit an event (SPEC 19.18): the URL is checked as it is typed.
struct EventFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editing: CalEvent?
    let channel: String?
    @State private var title = ""
    @State private var description = ""
    @State private var allDay = false
    @State private var start = Date().addingTimeInterval(86400)
    @State private var end = Date().addingTimeInterval(86400 + 7200)
    @State private var hasEnd = true
    @State private var location = ""
    @State private var online = ""
    @State private var visibility: BelfryCore.Visibility = .members
    @State private var byApplication = false
    @State private var prompt = ""
    @State private var slug = ""
    @State private var slugEdited = false
    @State private var slugState: SlugCheck?
    @State private var cover: String?
    @State private var coverItem: PhotosPickerItem?
    @State private var coverBusy = false
    @State private var error: String?
    @State private var loaded = false
    @State private var done = false

    var body: some View {
        let places = model.derive.eventPlaces(channel ?? generalId).filter { location.isEmpty || $0.lowercased().hasPrefix(location.lowercased()) && $0 != location }.prefix(4)
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).font(.body)
                        .onChange(of: title) { _, t in if !slugEdited && editing == nil { slug = EventLinks.slugOf(t) } }
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        HStack { Label(cover == nil ? "Add a cover" : "Change the cover", systemImage: "photo"); if coverBusy { ProgressView().controlSize(.small) } }
                    }
                }
                Section {
                    Toggle("All day", isOn: $allDay)
                    DatePicker("Starts", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    Toggle("Ends", isOn: $hasEnd)
                    if hasEnd { DatePicker("Ends", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute]) }
                }
                Section("Where") {
                    TextField("A place", text: $location).font(.body)
                    ForEach(Array(places), id: \.self) { p in Button(p) { location = p } }
                    TextField("Online link (https://…)", text: $online).font(.body).keyboardType(.URL).textInputAutocapitalization(.never)
                    if online.isEmpty { Button("Make a Jitsi link") { online = Actions.jitsiLink(title.isEmpty ? "meeting" : title) } }
                }
                Section("About") { TextField("What happens (Markdown)", text: $description, axis: .vertical).lineLimit(3...10).font(.body) }
                Section {
                    Picker("Who sees it", selection: $visibility) {
                        ForEach(BelfryCore.Visibility.allCases, id: \.self) { v in Text(v.label).tag(v) }
                    }
                    Text(visibility.hint).font(.caption).foregroundStyle(.secondary)
                    if editing == nil {
                        Picker("Who can come", selection: $byApplication) { Text("Anyone").tag(false); Text("By application").tag(true) }
                        if byApplication { TextField("Why would you like to come?", text: $prompt, axis: .vertical).lineLimit(1...4).font(.body) }
                    }
                }
                Section {
                    HStack(spacing: 2) {
                        Text("…/events/").foregroundStyle(.secondary)
                        TextField("name", text: $slug).font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: slug) { _, s in
                                let c = EventLinks.cleanSlug(s)
                                if c != s { slug = c }
                                slugEdited = true
                            }
                    }
                    if let st = slugState, !slug.isEmpty {
                        Text(st.free ? "Free" : st.problem ?? "Taken").font(.caption).foregroundStyle(st.free ? .green : .red)
                    }
                } header: { Text("Its address") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle(editing == nil ? "New event" : "Edit the event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton(editing == nil ? "Make" : "Save") { await save() }
                        .disabled(title.jsTrim().isEmpty || done || coverBusy || (slugState.map { !$0.free } ?? false) && !slug.isEmpty)
                }
            }
            .task(id: slug) {
                guard !slug.isEmpty else { slugState = nil; return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                slugState = await model.slugCheck(slug, event: editing?.d ?? "")
            }
            .onChange(of: coverItem) { _, item in
                guard let item else { return }
                coverBusy = true
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let jpeg = Images.jpeg(data, max: 1600) {
                        cover = await model.uploadImage(jpeg, name: "cover.jpg")
                    }
                    coverBusy = false
                }
            }
            .onAppear(perform: load)
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let e = editing else { return }
        title = e.title
        description = e.description
        allDay = e.allDay
        start = Date(timeIntervalSince1970: TimeInterval(e.start))
        if let x = e.end { end = Date(timeIntervalSince1970: TimeInterval(x)) } else { hasEnd = false }
        location = e.location ?? ""
        online = e.links.first ?? ""
        visibility = e.visibility
        slug = e.slug ?? ""
        slugEdited = true
        cover = e.cover
    }

    func save() async {
        error = nil
        var f = EventForm(title: title.jsTrim())
        f.description = description.jsTrim()
        f.allDay = allDay
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .gregorian)
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        if allDay {
            f.startDate = day.string(from: start)
            f.endDate = hasEnd ? day.string(from: end) : nil
        } else {
            f.start = Int(start.timeIntervalSince1970)
            f.end = hasEnd ? Int(end.timeIntervalSince1970) : nil
        }
        f.tz = TimeZone.current.identifier
        f.location = location
        f.online = online
        f.visibility = visibility
        f.slug = slug
        f.cover = cover
        if editing == nil && byApplication { f.applicationPrompt = prompt.jsTrim() }
        if let e = editing {
            if let x = await model.editEvent(e, f) { error = x; return }
            done = true
            dismiss()
        } else {
            let (d, x) = await model.createEvent(f)
            done = true
            if let channel, let d {
                model.composerPrefill[channel] = EventLinks.url(domain: model.config.domain, link: slug.isEmpty ? d : slug)
            }
            if let x { error = x; return }
            dismiss()
            if channel == nil, let d { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { model.openEvent = d } }
        }
    }
}

/// The event's ticket types: add, edit, delete (no prices in v1).
struct TicketsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State private var editing: TicketForm?
    var body: some View {
        let list = model.derive.tickets(e).filter { !$0.implicit }
        NavigationStack {
            List {
                if list.isEmpty { Text("No tickets: anyone answers with an RSVP.").foregroundStyle(.secondary) }
                ForEach(list) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.title).font(.subheadline.weight(.semibold))
                            Text([t.quantity.map { "\($0) places" }, t.closed ? "by application" : "open", t.members ? "members only" : nil].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") {
                            var f = TicketForm(id: t.id, title: t.title)
                            f.summary = t.summary; f.quantity = t.quantity.map(String.init) ?? ""; f.closed = t.closed; f.prompt = t.prompt; f.members = t.members; f.position = t.position
                            editing = f
                        }
                        .buttonStyle(.borderless)
                        BusyButton("Delete", role: .destructive) { model.deleteTicket(t) }.buttonStyle(.borderless)
                    }
                }
                Button { var f = TicketForm(title: ""); f.position = list.count + 1; editing = f } label: { ActionRow(icon: "plus", title: "Add a ticket") }
            }
            .navigationTitle("Tickets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { editing.map { TicketKey(form: $0) } }, set: { editing = $0?.form })) { k in TicketFormSheet(e: e, form: k.form) }
        }
    }
}

struct TicketKey: Identifiable { let form: TicketForm; var id: String { form.id ?? "new" } }

struct TicketFormSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let e: CalEvent
    @State var form: TicketForm
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $form.title).font(.body)
                    TextField("In one line", text: $form.summary).font(.body)
                    TextField("Places (empty: no limit)", text: $form.quantity).keyboardType(.numberPad).font(.body)
                }
                Section {
                    Toggle("Needs an application", isOn: $form.closed)
                    if form.closed { TextField("Why would you like to come?", text: $form.prompt, axis: .vertical).lineLimit(1...4).font(.body) }
                    Toggle("Members only", isOn: $form.members)
                }
            }
            .navigationTitle(form.id == nil ? "New ticket" : "Edit ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { BusyButton("Save") { model.saveTicket(e, form); dismiss() }.disabled(form.title.jsTrim().isEmpty) }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct EventsList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String?
    @State private var tab: EventsTab = .upcoming
    @State private var make = false

    var body: some View {
        let _ = model.version
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !d.amGuest {
                    ToolbarItem(placement: .topBarLeading) { Button { make = true } label: { Label("New event", systemImage: "plus") } }
                }
            }
            .sheet(isPresented: $make) { EventFormSheet(editing: nil, channel: nil) }
        }
    }
}

struct EventRow: View {
    @EnvironmentObject var model: AppModel
    let e: CalEvent
    var body: some View {
        let d = model.derive
        HStack(spacing: 10) {
            if let c = e.cover, let u = URL(string: c), c.hasPrefix("https://") {
                AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { DateChip(at: e.start) }
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                DateChip(at: e.start)
            }
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
