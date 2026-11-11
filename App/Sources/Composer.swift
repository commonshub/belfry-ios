import BelfryCore
import PhotosUI
import SwiftUI

// The composer: @ picker (marks people who can't read the channel, with Invite / Add as a guest
// above the field), # picker for channel references (SPEC 19.14), photos, the ＋ menu (a
// Discord-style list: Photo, To-do, Pod, Proposal, Announcement), Send that can't fire twice.

struct Composer: View {
    @EnvironmentObject var model: AppModel
    var group: String = ""
    var placeholder = "Message"
    var canAnnounce = false
    var compact = false
    var autoFocus = false
    var threadMode = false
    var topic: String?
    let onSend: (String, [Attachment], Bool) -> Void
    @State private var text = ""
    @State private var picked = [(name: String, pubkey: String)]()
    @State private var refs = [(label: String, ref: String)]()
    @State private var photos = [PhotosPickerItem]()
    @State private var attachments = [Attachment]()
    @State private var announce = false
    @State private var sent = 0
    @State private var add = false
    @State private var photoPicker = false
    @State private var create: CreateKind?
    @State private var makeEvent = false
    @State private var notes = [String: String]()
    @FocusState private var focused: Bool

    var body: some View {
        let d = model.derive
        let g = model.group(group)
        VStack(spacing: 6) {
            if let q = Mentions.query(beforeCaret: text) {
                let list = people(q)
                if !list.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(list, id: \.pubkey) { p in
                            Button { pick(p.pubkey, p.name) } label: {
                                HStack(spacing: 10) {
                                    Avatar(pubkey: p.pubkey, size: 26)
                                    Text(p.name).font(.subheadline)
                                    if let k = d.kindLabel(p.pubkey) { Text(k).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if g != nil && !d.inChannel(g, p.pubkey) { Text("not in this channel").font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Mention \(p.name)")
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            } else if !threadMode, let q = ChannelRefs.query(beforeCaret: text) {
                let list = d.channelCandidates(q)
                if !list.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(list, id: \.group.id) { c in
                            Button { pickChannel(c, query: q) } label: {
                                HStack(spacing: 10) {
                                    ChannelGlyph(group: c.group, size: 20)
                                    Text(c.group.name).font(.subheadline)
                                    Spacer()
                                }
                                .padding(.vertical, 6).padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Link the channel \(c.group.name)")
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            ForEach(outsiders(g), id: \.self) { pk in
                OutsiderNote(pubkey: pk, group: group, note: notes[pk]) { notes[pk] = $0 }
            }
            if announce {
                HStack {
                    Label("Announcement: sent to the channel and e-mailed to its followers", systemImage: "megaphone").font(.caption)
                    Spacer()
                    Button { announce = false } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Not an announcement")
                }.foregroundStyle(Color.bronze)
            }
            if !attachments.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(attachments, id: \.file) { a in
                        HStack(spacing: 4) {
                            Image(systemName: a.mime.hasPrefix("image/") ? "photo" : "paperclip")
                            Text(a.name).lineLimit(1).font(.caption)
                            Button { attachments.removeAll { $0.file == a.file } } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Remove \(a.name)")
                        }
                        .padding(6).background(.thinMaterial, in: Capsule())
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !compact && !threadMode {
                    Button { add = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Add a photo, a to-do, a pod, a proposal…")
                }
                TextField(announce ? "Announcement" : placeholder, text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(text.jsTrim().isEmpty && attachments.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, compact ? 0 : 12)
        .padding(.vertical, compact ? 0 : 8)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .onChange(of: model.launchEventForm) { _, on in
            if on, !compact, !threadMode { model.launchEventForm = false; makeEvent = true }
        }
        .onChange(of: model.composerPrefill[group]) { _, v in
            if let v, !compact, !threadMode { text = text.isEmpty ? v + " " : text + " " + v; model.composerPrefill[group] = nil }
        }
        .onAppear {
            if autoFocus { focused = true }
            if !compact && !threadMode && model.launchAdd { model.launchAdd = false; add = true }
            if !compact && !threadMode && model.launchEventForm { model.launchEventForm = false; add = false; makeEvent = true }
        }
        .onChange(of: photos) { _, items in load(items) }
        .sheet(isPresented: $add) {
            AddMenu(group: group, canAnnounce: canAnnounce) { choice in
                add = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    switch choice {
                    case .photo: photoPicker = true
                    case .announcement: announce = true
                    case .create(let k): create = k
                    case .event: makeEvent = true
                    }
                }
            }
        }
        .photosPicker(isPresented: $photoPicker, selection: $photos, maxSelectionCount: 6, matching: .images)
        .sheet(item: $create) { k in CreateSheet(kind: k, parent: group) }
        .sheet(isPresented: $makeEvent) { EventFormSheet(editing: nil, channel: group) }
    }

    func people(_ q: String) -> [(pubkey: String, name: String)] {
        let ql = q.lowercased()
        return Array(model.derive.people.filter { p in ql.isEmpty || p.name.lowercased().split(separator: " ").contains { $0.hasPrefix(ql) } }.prefix(6))
    }

    /// People picked here who can't read this channel (each gets a note with Invite).
    func outsiders(_ g: Channel?) -> [String] {
        guard let g else { return [] }
        var out = [String]()
        for p in picked where text.contains("@" + p.name) && !model.derive.inChannel(g, p.pubkey) && !out.contains(p.pubkey) { out.append(p.pubkey) }
        return out
    }

    func pick(_ pk: String, _ name: String) {
        guard let q = Mentions.query(beforeCaret: text) else { return }
        text = String(text.dropLast(q.count + 1)) + "@" + name + " "
        picked.append((name, pk))
    }

    func pickChannel(_ c: ChannelPick, query q: String) {
        let label = "#" + c.group.name
        text = String(text.dropLast(q.count + 1)) + label + " "
        if !refs.contains(where: { $0.label == label }) { refs.append((label, c.ref)) }
    }

    func send() {
        let typed = text.jsTrim()
        guard !typed.isEmpty || !attachments.isEmpty else { return }
        let t = ChannelRefs.substitute(Mentions.substitute(typed, picked: picked), picked: refs)
        onSend(t, attachments, canAnnounce && announce)
        text = ""
        picked = []
        refs = []
        attachments = []
        announce = false
        notes = [:]
        sent += 1
    }

    func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        photos = []
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let img = UIImage(data: data)
                let jpeg = img?.jpegData(compressionQuality: 0.85) ?? data
                let name = "photo-\(Int.now).jpg"
                if let a = model.saveAttachment(jpeg, name: name, mime: "image/jpeg", width: img.map { Int($0.size.width * $0.scale) }, height: img.map { Int($0.size.height * $0.scale) }) {
                    attachments.append(a)
                }
            }
        }
    }
}

/// "<name> can't read this channel" with Invite (a member: a direct message with the link; a
/// closed pod I administer: let in first) or Add as a guest (a guest of another channel).
struct OutsiderNote: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    let group: String
    let note: String?
    let set: (String) -> Void
    var body: some View {
        let guest = model.derive.isGuest(pubkey)
        HStack(spacing: 8) {
            Image(systemName: "eye.slash").foregroundStyle(.secondary)
            Text(note ?? "\(model.realNameOrKey(pubkey)) can't read this channel.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if note == nil {
                BusyButton(guest ? "Add as a guest" : "Invite") {
                    set(await model.inviteHere(pubkey, to: group))
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

enum CreateKind: String, Identifiable { case todo, pod, proposal; var id: String { rawValue } }
enum AddChoice { case photo, announcement, event, create(CreateKind) }

/// The ＋ menu as a list.
struct AddMenu: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let canAnnounce: Bool
    let choose: (AddChoice) -> Void
    var body: some View {
        let guest = model.derive.amGuest
        NavigationStack {
            List {
                Section {
                    Button { choose(.photo) } label: { ActionRow(icon: "photo", title: "Photo") }
                    Button { choose(.create(.todo)) } label: { ActionRow(icon: "checklist", title: "To-do", detail: "Something someone here should do") }
                }
                if !guest {
                    Section {
                        Button { choose(.event) } label: { ActionRow(icon: "calendar", title: "Event", detail: "Its own page and address; its card shows here") }
                        Button { choose(.create(.pod)) } label: { ActionRow(icon: "hexagon", title: "Pod", detail: "A smaller group inside this channel") }
                        Button { choose(.create(.proposal)) } label: { ActionRow(icon: "doc.text", title: "Proposal", detail: "Something to decide together") }
                    }
                }
                if canAnnounce {
                    Section {
                        Button { choose(.announcement) } label: { ActionRow(icon: "megaphone", title: "Announcement", detail: "E-mailed to the channel's followers") }
                    }
                }
            }
            .navigationTitle("Add")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// Make a to-do, a pod or a proposal in this channel.
struct CreateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let kind: CreateKind
    let parent: String
    @State private var title = ""
    @State private var about = ""
    @State private var text = ""
    @State private var closed = false
    @State private var prompt = ""
    @State private var status: ProposalStatus = .draft

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .todo:
                    Section { TextField("What needs doing?", text: $title, axis: .vertical).lineLimit(1...4).font(.body) }
                case .pod:
                    Section {
                        TextField("Name", text: $title).font(.body)
                        TextField("What is it for?", text: $about, axis: .vertical).lineLimit(2...5).font(.body)
                    }
                    Section {
                        Picker("Who can join", selection: $closed) {
                            Text("Anyone here").tag(false)
                            Text("By application").tag(true)
                        }
                        if closed { TextField(Actions.defaultPrompt, text: $prompt, axis: .vertical).lineLimit(1...4).font(.body) }
                    } footer: { Text(closed ? "People answer the question; the pod's members let them in." : "Anyone in the channel can join.") }
                case .proposal:
                    Section {
                        TextField("Title", text: $title).font(.body)
                        TextField("In one line", text: $about).font(.body)
                        TextField("The proposal (Markdown)", text: $text, axis: .vertical).lineLimit(4...12).font(.body)
                    }
                    Section {
                        Picker("Start as", selection: $status) {
                            Text("Draft").tag(ProposalStatus.draft)
                            Text("Open for feedback").tag(ProposalStatus.feedback)
                        }
                    }
                }
            }
            .navigationTitle(kind == .todo ? "New to-do" : kind == .pod ? "New pod" : "New proposal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton(kind == .todo ? "Add" : "Create") { make() }.disabled(title.jsTrim().isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    func make() {
        let t = title.jsTrim()
        switch kind {
        case .todo:
            model.addTodo(t, in: parent)
            dismiss()
        case .pod:
            let id = model.createPod(name: t, about: about.jsTrim(), parent: parent, closed: closed, prompt: prompt)
            dismiss()
            openChannel(id, nil)
        case .proposal:
            let id = model.createProposal(NewProposal(title: t, summary: about.jsTrim(), text: text.jsTrim(), status: status), parent: parent)
            dismiss()
            openChannel(id, nil)
        }
    }
}
