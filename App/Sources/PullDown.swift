import BelfryCore
import SwiftUI

// The ONE line under a channel's name (SPEC 19.13, the web's ChannelLine.tsx) and what it pulls
// down: Pinned, Coming up, To decide, To do, Pods, Topics, the people line, the description.
// On iPhone the pull-down is a sheet with detents (SPEC 16).

struct ChannelLineBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    let topic: String?
    let open: () -> Void
    let showAll: () -> Void
    let review: () -> Void

    var body: some View {
        let line = model.derive.channelLine(id, now: .now, topic: topic, hiddenPins: model.hiddenPins)
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 6) {
                    LineIconView(line: line)
                    (Text(line.bold).fontWeight(.semibold) + Text(line.text))
                        .font(.footnote)
                        .foregroundStyle(line.quiet ? Color.secondary : Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    ForEach(line.counts, id: \.kind) { c in
                        HStack(spacing: 2) {
                            Image(systemName: countIcon(c.kind)).font(.caption2)
                            Text(c.plus ? "+\(c.n)" : "\(c.n)").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(c.n) \(c.label)")
                    }
                }
            }
            .buttonStyle(.plain)
            if let pill = line.pill {
                Button { act(line.action) } label: {
                    Text(pill).font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(line.ask ? Color.bronze : Color.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(line.ask ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(line.action == nil)
            }
        }
        .padding(.horizontal).padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    func act(_ a: LineAction?) {
        switch a {
        case .showAll?: showAll()
        case .open?: open()
        case .review?: review()
        case .openProposal(let g)?: openChannel(g, nil)
        case .openEvent(let c)?: model.openEvent = c
        case nil: break
        }
    }

    func countIcon(_ k: String) -> String {
        switch k {
        case "events": return "calendar"
        case "proposals": return "doc.text"
        case "pods": return "hexagon"
        default: return "checklist"
        }
    }
}

struct LineIconView: View {
    let line: ChannelLine
    var body: some View {
        switch line.icon {
        case .pod:
            PodShape(members: line.podMembers).stroke(Color.secondary, lineWidth: 1.4).frame(width: 14, height: 14)
        default:
            Image(systemName: symbol).font(.caption).foregroundStyle(line.ask ? Color.bronze : Color.secondary)
        }
    }
    var symbol: String {
        switch line.icon {
        case .people: return "person.2"
        case .topic: return "number"
        case .proposal: return "doc.text"
        case .pod: return "hexagon"
        case .event: return "calendar"
        case .pin: return "pin"
        }
    }
}

struct PullDownSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let id: String
    @Binding var topic: String?
    let openDetails: () -> Void
    let showMessage: (String) -> Void
    @State private var newTodo = ""

    var body: some View {
        let _ = model.version
        let d = model.derive
        let now = Int.now
        let f = d.channelFacts(id, now: now)
        let g = f.group
        NavigationStack {
            List {
                if let g, let p = g.parent, let parent = model.group(p) {
                    Section {
                        Button { dismiss(); openChannel(p, nil) } label: {
                            ActionRow(icon: "arrow.up.left", title: "\(g.isProposal ? "Proposal" : "Pod") in \(parent.isPod ? parent.name : "# " + parent.name)")
                        }
                    }
                }
                if let p = f.own { ProposalSection(p: p) }
                if let g, g.isPod, d.canAdmin(g), !g.applications.isEmpty {
                    Section("\(g.applications.count) asking to join") {
                        ForEach(g.applications, id: \.pubkey) { a in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Avatar(pubkey: a.pubkey, size: 28); Text(model.name(a.pubkey)).font(.subheadline.weight(.semibold)) }
                                if !a.answer.isEmpty { Text(a.answer).font(.subheadline).foregroundStyle(.secondary) }
                                HStack {
                                    BusyButton("Let in") { model.admit(id, a.pubkey) }.buttonStyle(.borderedProminent)
                                    BusyButton("Decline", role: .destructive) { model.declineApplicant(id, a.pubkey) }.buttonStyle(.bordered)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                if !f.pins.isEmpty {
                    Section("Pinned") {
                        ForEach(f.pins) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Avatar(pubkey: m.pubkey, size: 20)
                                    Text(model.name(m.pubkey)).font(.caption.weight(.semibold))
                                    Text(Format.day(m.at)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(d.pinLine(m)).font(.subheadline).lineLimit(3)
                                HStack(spacing: 16) {
                                    Button("Show in the channel") { showMessage(m.id) }
                                    if !model.hiddenPins.contains(m.id) { Button("Got it, hide") { model.hidePin(m.id) } }
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                if !f.events.isEmpty {
                    Section("Coming up") {
                        ForEach(f.events.prefix(3)) { e in
                            Button { dismiss(); model.openEvent = e.coord } label: {
                                HStack(spacing: 10) {
                                    DateChip(at: e.start)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        Text(d.lineDay(e.start, now: now) + " · " + d.lineWhen(e)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let s = d.stateLabel(e) { Chip(text: s, tint: .bronze) } else if e.status != .cancelled { Chip(text: "RSVP", tint: .bronze) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if f.events.count > 3 {
                            Button { dismiss(); model.showEvents = id } label: { ActionRow(icon: "calendar", title: "All \(f.events.count) events") }
                        }
                    }
                }
                if !f.proposals.isEmpty {
                    Section("To decide") {
                        ForEach(f.proposals) { p in
                            Button { dismiss(); openChannel(p.groupId, nil) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.title).font(.subheadline.weight(.semibold))
                                        Text(p.status.label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if p.votingNow { Chip(text: d.myVote(p) == nil ? "Vote" : "Voted", tint: d.myVote(p) == nil ? .bronze : .secondary) }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section("To do") {
                    ForEach(f.todos.prefix(4)) { t in TodoRow(t: t, group: id) }
                    if f.todos.count > 4 {
                        Button { openDetails() } label: { ActionRow(icon: "checklist", title: "All \(f.todos.count) to-dos") }
                    }
                    HStack {
                        TextField("Add a to-do", text: $newTodo).font(.body)
                        BusyButton {
                            model.addTodo(newTodo, in: id)
                            newTodo = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(newTodo.jsTrim().isEmpty)
                        .accessibilityLabel("Add the to-do")
                    }
                }
                if !f.pods.isEmpty {
                    Section("Pods") {
                        ForEach(f.pods) { p in
                            Button { dismiss(); openChannel(p.id, nil) } label: {
                                HStack(spacing: 10) {
                                    ChannelGlyph(group: p, size: 22)
                                    Text(p.name).font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(p.members.count) \(p.members.count == 1 ? "member" : "members")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                TopicsSection(id: id, topic: $topic) { dismiss() }
                Section {
                    Button { openDetails() } label: {
                        ActionRow(icon: "person.2", title: peopleLine(f.active.count), detail: "Members, files, to-dos and settings")
                    }
                    if let about = g?.about, !about.isEmpty {
                        Text(about.components(separatedBy: "\n").first ?? "").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(g.map { $0.isPod ? $0.name : "# " + $0.name } ?? id)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A to-do with a box that ticks it off and who is on it.
struct TodoRow: View {
    @EnvironmentObject var model: AppModel
    let t: TodoTask
    let group: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            BusyButton {
                model.todo(t, in: group, t.done ? "undone" : "done")
            } label: {
                Image(systemName: t.done ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(t.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(t.done ? "Done. Mark as not done" : "Tick off")
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.subheadline).strikethrough(t.done)
                Text(model.derive.todoWho(t)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !t.done {
                if t.assignee == model.me {
                    BusyButton("Let go") { model.todo(t, in: group, "unclaim") }.font(.caption).buttonStyle(.borderless)
                } else if t.assignee == nil {
                    BusyButton("I'll do it") { model.todo(t, in: group, "claim") }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
    }
}

/// A proposal's own state: status, version, author, the vote while it is open, and its admins' status menu.
struct ProposalSection: View {
    @EnvironmentObject var model: AppModel
    let p: Proposal
    @State private var revise = false
    var body: some View {
        let d = model.derive
        let mine = d.myVote(p)
        Section("Proposal") {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.title).font(.headline)
                Text("\(p.status.label) · version \(p.version) · by \(model.name(p.author))").font(.caption).foregroundStyle(.secondary)
                if !p.summary.isEmpty { Text(p.summary).font(.subheadline) }
            }
            if !p.text.isEmpty { MarkdownText(text: p.text).font(.subheadline) }
            if p.votingNow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(p.tally["yes"] ?? 0) yes · \(p.tally["no"] ?? 0) no · \(p.tally["abstain"] ?? 0) abstain").font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        ForEach(Proposal.voteOptions, id: \.id) { o in
                            if mine == o.id {
                                BusyButton(o.label) { model.vote(p, o.id) }.buttonStyle(.borderedProminent)
                            } else {
                                BusyButton(o.label) { model.vote(p, o.id) }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            if d.canDecide(p) {
                Menu {
                    ForEach(ProposalStatus.allCases.filter { $0 != p.status }, id: \.self) { s in
                        Button(s.label) { model.setStatus(p, s) }
                    }
                } label: { ActionRow(icon: "flag", title: "Change the status", detail: p.status.label) }
            }
            if p.author == model.me {
                Button { revise = true } label: { ActionRow(icon: "doc.badge.plus", title: "New version", detail: "Version \(p.version + 1)") }
            }
        }
        .sheet(isPresented: $revise) { ReviseProposalSheet(p: p) }
    }
}

/// A new version of my proposal: the text replaced, a note in its chat, a new vote while under vote.
struct ReviseProposalSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let p: Proposal
    @State private var title = ""
    @State private var summary = ""
    @State private var text = ""
    @State private var note = ""
    @State private var loaded = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).font(.body)
                    TextField("In one line", text: $summary).font(.body)
                    TextField("The proposal (Markdown)", text: $text, axis: .vertical).lineLimit(4...14).font(.body)
                }
                Section { TextField("What changed (optional)", text: $note, axis: .vertical).lineLimit(1...4).font(.body) } footer: { Text(p.status == .voting ? "A new vote opens for version \(p.version + 1)." : "Everyone in its chat sees the new version.") }
            }
            .navigationTitle("Version \(p.version + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Publish") { model.reviseProposal(p, title: title.jsTrim(), summary: summary.jsTrim(), text: text.jsTrim(), note: note); dismiss() }
                        .disabled(title.jsTrim().isEmpty)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = p.title; summary = p.summary; text = p.text
            }
        }
    }
}

/// The channel's topics: pinned first, then by use; tap filters the channel, Pin / Unpin.
struct TopicsSection: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @Binding var topic: String?
    let done: () -> Void
    var body: some View {
        let d = model.derive
        let pinned = d.pinnedTopics(id).filter { $0 != Derive.announcement }
        let counts = d.topicCounts(id)
        let rest = counts.filter { !pinned.contains($0.topic) }
        if !pinned.isEmpty || !rest.isEmpty || d.hasAnnouncements(id) {
            Section("Topics") {
                if d.hasAnnouncements(id) {
                    Button { topic = Derive.announcement; done() } label: { ActionRow(icon: "megaphone", title: "Announcements") }
                }
                ForEach(pinned, id: \.self) { t in row(t, counts.first { $0.topic == t }?.count ?? 0, pinned: true) }
                ForEach(rest.prefix(12), id: \.topic) { c in row(c.topic, c.count, pinned: false) }
            }
        }
    }

    func row(_ t: String, _ n: Int, pinned: Bool) -> some View {
        HStack {
            Button { topic = t; done() } label: { ActionRow(icon: pinned ? "pin" : "number", title: "#" + t, detail: "\(n) \(n == 1 ? "message" : "messages")") }
                .buttonStyle(.plain)
            BusyButton(pinned ? "Unpin" : "Pin") { model.pinTopic(t, in: id, !pinned) }.font(.caption).buttonStyle(.borderless)
        }
    }
}
