import BelfryCore
import SwiftUI

// A thread's own screen ("Open thread"; Reply opens it with its box focused, as the web chat
// does since chat-source 85ede89), and the search sheet of a channel (this channel or all).

struct ThreadView: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let rootId: String
    var focusReply = false
    @State private var actionsFor: Message?
    @State private var editing: Message?

    var body: some View {
        let _ = model.version
        let d = model.derive
        let root = d.message(group, rootId)
        let replies = d.threadReplies(group, rootId)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let root {
                        MessageRow(m: root, group: group, first: true, reactions: d.reactions(group)[root.id] ?? [], thread: nil, threadOpen: false,
                                   announce: d.isAnnouncement(root, d.group(group)), todo: d.todosBySource(group)[root.id],
                                   onThread: {}, onOpenThread: {}, onReply: {}, onHold: { hold(root) })
                        HStack {
                            Text(replies.isEmpty ? "No replies yet" : "\(replies.count) \(replies.count == 1 ? "reply" : "replies")")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            VStack { Divider() }
                        }
                        .padding(.horizontal)
                    } else {
                        ContentUnavailableView("This message is gone", systemImage: "bubble.left")
                    }
                    ForEach(replies) { r in
                        ReplyRow(r: r) { hold(r) }.padding(.horizontal).id(r.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: replies.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
        .safeAreaInset(edge: .bottom) {
            if model.guestReading {
                GuestBar(group: group)
            } else if let root {
                Composer(group: group, placeholder: replies.isEmpty ? "Reply (starts a thread)" : "Reply in the thread", autoFocus: focusReply, threadMode: true) { text, _, _ in
                    model.reply(text, in: group, to: root)
                }
            }
        }
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $actionsFor) { m in
            MessageActions(m: m, group: group, onReply: {}, onOpenThread: {}, onEdit: { editing = m })
        }
        .sheet(item: $editing) { m in EditSheet(m: m, group: group) }
    }

    func hold(_ m: Message) { if model.guestReading { model.joinAsked = true } else { actionsFor = m } }
}

/// Search this channel or all (accent-folded words; tap a result to see it in its channel).
struct ChannelSearch: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let channel: String
    let open: (String, String) -> Void
    @State private var query = ""
    @State private var everywhere = false
    @FocusState private var focused: Bool

    var body: some View {
        let hits = model.derive.search(query, channel: everywhere ? nil : channel)
        let words = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        NavigationStack {
            List {
                Section {
                    Picker("Where", selection: $everywhere) {
                        Text("This channel").tag(false)
                        Text("All channels").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if !words.isEmpty {
                    Section(hits.isEmpty ? "Nothing found" : "\(hits.count == 200 ? "200+" : String(hits.count)) \(hits.count == 1 ? "result" : "results")") {
                        ForEach(hits, id: \.m.id) { h in
                            Button { open(h.groupId, h.m.id) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Avatar(pubkey: h.m.pubkey, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(model.name(h.m.pubkey)).font(.subheadline.bold())
                                            if everywhere, let g = model.group(h.groupId) { Text(g.isPod ? g.name : "# " + g.name).font(.caption).foregroundStyle(.secondary) }
                                            Spacer()
                                            Text(Format.short(h.m.at)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(marked(model.derive.plainRefs(h.m.text), words)).font(.subheadline).lineLimit(3)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: everywhere ? "Search all channels" : "Search this channel")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { if model.launch.screen == "chsearch" && query.isEmpty { query = "ladder" } }
        }
    }

    /// The words found, marked (bold, bronze), accents and case ignored.
    func marked(_ text: String, _ words: [String]) -> AttributedString {
        var a = AttributedString(text)
        let folded = fold(text)
        guard folded.count == text.count else { return a }
        for w in words where !w.isEmpty {
            var from = folded.startIndex
            while let r = folded.range(of: w, range: from..<folded.endIndex) {
                let lo = folded.distance(from: folded.startIndex, to: r.lowerBound)
                let len = folded.distance(from: r.lowerBound, to: r.upperBound)
                let s = a.index(a.startIndex, offsetByCharacters: lo)
                let e = a.index(s, offsetByCharacters: len)
                a[s..<e].foregroundColor = .bronze
                a[s..<e].inlinePresentationIntent = .stronglyEmphasized
                from = r.upperBound
            }
        }
        return a
    }
}
