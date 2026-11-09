import BelfryCore
import PhotosUI
import SwiftUI

// A channel: the feed (day separators, blocks per author, reactions, inline threads, resurfaced
// threads, guest joins), the composer, and the channel details as a sheet with detents.

struct ChannelView: View {
    @EnvironmentObject var model: AppModel
    let id: String
    var focus: String?
    @State private var openThreads = Set<String>()
    @State private var replyTo: String?
    @State private var details = false
    @State private var invite = false
    @State private var didLaunch = false

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        let feed = model.derive.feed(id)
        let threads = model.derive.threadsOf(id)
        let reactions = model.derive.reactions(id)
        let active = model.derive.recentlyActive(id)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if feed.isEmpty {
                        EmptyChannel(name: g.map { "\($0.icon) \($0.name)" } ?? id) { invite = true }
                    }
                    ForEach(Array(feed.enumerated()), id: \.element.id) { i, item in
                        let prev: FeedItem? = i > 0 ? feed[i - 1] : nil
                        if dayChanged(prev?.at, item.at) { DaySeparator(at: item.at) }
                        switch item {
                        case .message(let m):
                            MessageRow(m: m, group: id, first: startsBlock(prev, m), reactions: reactions[m.id] ?? [],
                                       thread: threads[m.id], threadOpen: openThreads.contains(m.id), announce: model.derive.isAnnouncement(m, g),
                                       onThread: { toggle(m.id) }, onReply: { open(m.id, reply: true) })
                                .id(m.id)
                            if openThreads.contains(m.id) {
                                InlineThread(group: id, root: m, focus: replyTo == m.id) { toggle(m.id) }
                            }
                        case .join(let j):
                            JoinLine(join: j)
                        case .activity(let root, let last):
                            let key = "act:" + root.id
                            ThreadActivity(root: root, last: last, open: openThreads.contains(key)) { toggle(key) }
                            if openThreads.contains(key) {
                                InlineThread(group: id, root: root, focus: replyTo == key) { toggle(key) }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.refresh() }
            .onAppear {
                model.markSeen(id)
                if let focus { DispatchQueue.main.async { withAnimation { proxy.scrollTo(focus, anchor: .center) } } }
                applyLaunch()
            }
            .onChange(of: feed.count) { _, _ in
                if focus == nil { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) {
                Composer(placeholder: "Message \(g?.name ?? id)", canAnnounce: model.derive.canAdmin(g)) { text, attachments, announce in
                    model.post(text, in: id, attachments: attachments, announce: announce)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { details = true } label: {
                    VStack(spacing: 0) {
                        Text("\(g?.icon ?? "#") \(g?.name ?? id)").font(.headline).foregroundStyle(.primary)
                        Text(active.isEmpty ? "Nobody active this month yet" : "\(active.count) active \(active.count == 1 ? "member" : "members") this month")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(g?.name ?? id). \(active.count) active this month. Show the channel details.")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { invite = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Invite people")
            }
        }
        .sheet(isPresented: $details) { ChannelDetails(id: id) }
        .sheet(isPresented: $invite) { InviteSheet(id: id) }
    }

    func toggle(_ key: String) {
        withAnimation(.snappy) {
            if openThreads.contains(key) { openThreads.remove(key) } else { openThreads.insert(key) }
        }
    }

    func open(_ key: String, reply: Bool) {
        withAnimation(.snappy) { openThreads.insert(key) }
        if reply { replyTo = key }
    }

    func startsBlock(_ prev: FeedItem?, _ m: Message) -> Bool {
        guard case .message(let p)? = prev else { return true }
        if openThreads.contains(p.id) { return true }
        return dayChanged(p.ev.createdAt, m.ev.createdAt) || p.ev.pubkey != m.ev.pubkey || m.ev.createdAt - p.ev.createdAt > 300
    }

    func dayChanged(_ a: Int?, _ b: Int) -> Bool {
        guard let a else { return true }
        return !Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(a)), inSameDayAs: Date(timeIntervalSince1970: TimeInterval(b)))
    }

    func applyLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        switch model.launch.screen {
        case "thread":
            if let root = model.derive.threadsInOrder(id).first?.root { openThreads.insert(root) }
        case "details": details = true
        case "invite": invite = true
        default: break
        }
    }
}

struct DaySeparator: View {
    let at: Int
    var body: some View {
        HStack {
            VStack { Divider() }
            Text(Format.day(at)).font(.caption.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            VStack { Divider() }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityAddTraits(.isHeader)
    }
}

enum Format {
    static func day(_ at: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(at))
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func time(_ at: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .omitted, time: .shortened)
    }

    static func ago(_ at: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(at)).formatted(.relative(presentation: .named))
    }
}

struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    let first: Bool
    let reactions: [Reaction]
    let thread: ThreadInfo?
    let threadOpen: Bool
    let announce: Bool
    let onThread: () -> Void
    let onReply: () -> Void
    @State private var tapped = 0

    var body: some View {
        let pending = model.pending(m.id)
        HStack(alignment: .top, spacing: 10) {
            if first || announce { Avatar(pubkey: m.ev.pubkey, size: 36) } else { Color.clear.frame(width: 36, height: 1) }
            VStack(alignment: .leading, spacing: 4) {
                if first || announce {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(senderName).font(.subheadline.weight(.semibold))
                        Text(Format.time(m.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                        if announce { Label("Announcement", systemImage: "megaphone").font(.caption2.weight(.semibold)).foregroundStyle(Color.bronze) }
                        if m.ev.hasTag("client", "belfry-mail") { Label("via e-mail", systemImage: "envelope").font(.caption2).foregroundStyle(.secondary) }
                    }
                }
                if !m.text.isEmpty { MarkdownText(text: displayText) }
                ForEach(m.media, id: \.url) { media in MediaView(media: media) }
                if !reactions.isEmpty {
                    ReactionBar(reactions: reactions) { emoji in model.toggleReaction(emoji, on: m, in: group); tapped += 1 }
                }
                if let thread, thread.count > 0 {
                    Button(action: onThread) {
                        HStack(spacing: 6) {
                            HStack(spacing: -6) { ForEach(thread.who.prefix(3), id: \.self) { Avatar(pubkey: $0, size: 18) } }
                            Text(threadOpen ? "Hide replies" : "\(thread.count) \(thread.count == 1 ? "reply" : "replies")").font(.caption.weight(.semibold))
                            Text(Format.time(thread.last)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.bronze)
                    .accessibilityLabel(threadOpen ? "Hide replies" : "\(thread.count) replies")
                }
                if let p = pending {
                    if p.status == .failed {
                        HStack(spacing: 6) {
                            Label("Not sent", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                            Button("Retry") { model.retry(p.localId) }.font(.caption.weight(.semibold))
                        }.font(.caption)
                    } else {
                        Label(p.stateText, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, first ? 8 : 2)
        .opacity(pending == nil ? 1 : 0.65)
        .background(announce ? Color.bronze.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: tapped)
        .contextMenu {
            if pending == nil {
                ControlGroup {
                    ForEach(EmojiUsage.top(4), id: \.self) { e in
                        Button(e) { model.toggleReaction(e, on: m, in: group) }
                    }
                }
                Menu("More reactions") {
                    ForEach(moreEmojis, id: \.self) { e in Button(e) { model.toggleReaction(e, on: m, in: group) } }
                }
                Button { onReply() } label: {
                    Label(thread.map { $0.count > 0 ? "Reply in the thread (\($0.count))" : "Reply" } ?? "Reply (starts a thread)", systemImage: "arrowshape.turn.up.left")
                }
            }
            Button { UIPasteboard.general.string = m.text } label: { Label("Copy text", systemImage: "doc.on.doc") }
            if m.ev.pubkey == model.me {
                Button(role: .destructive) { model.delete(m, in: group) } label: { Label("Delete message", systemImage: "trash") }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Touch and hold to react or reply")
    }

    var senderName: String {
        if model.profiles[m.ev.pubkey]?.name == nil, m.ev.hasTag("client", "belfry-drop") { return "Drop box" }
        return model.name(m.ev.pubkey)
    }

    /// A member's e-mail: the "**Subject**" line the bridge puts first is shown as the subject.
    var displayText: String {
        guard m.ev.hasTag("client", "belfry-mail"), let s = m.ev.tag("subject"), !s.isEmpty else { return m.text }
        let head = "**\(s)**"
        return m.text.hasPrefix(head) ? "**\(s)**\n" + m.text.dropFirst(head.count).trimmingCharacters(in: .whitespacesAndNewlines) : m.text
    }

    let moreEmojis = ["🔥", "👏", "😍", "🤔", "😮", "😢", "🙌", "💪", "✅", "❌", "💯", "🚀", "✨", "🌱", "☕", "🍕", "👋", "🤝", "💡", "📌"]
}

struct ReactionBar: View {
    @EnvironmentObject var model: AppModel
    let reactions: [Reaction]
    let toggle: (String) -> Void

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(reactions, id: \.emoji) { r in
                Button { toggle(r.emoji) } label: {
                    Text("\(r.emoji) \(r.who.count)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(r.mine != nil ? Color.bronze.opacity(0.15) : Color.secondary.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(r.mine != nil ? Color.bronze : .clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(r.emoji), \(r.who.count). \(r.who.map(model.name).joined(separator: ", "))")
                .accessibilityAddTraits(r.mine != nil ? .isSelected : [])
            }
        }
    }
}

/// Wraps its children on several lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            x += s.width + spacing
            maxX = max(maxX, x)
            line = max(line, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

struct MediaView: View {
    let media: Media
    var body: some View {
        if media.mime.hasPrefix("image/"), let url = URL(string: media.url) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: Label(media.name ?? "Photo", systemImage: "photo").foregroundStyle(.secondary)
                default: ProgressView().frame(height: 120)
                }
            }
            .frame(maxWidth: 280, maxHeight: 280, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(media.name ?? "Photo")
        } else if let url = URL(string: media.url), url.scheme == "https" {
            Link(destination: url) { Label(media.name ?? "File", systemImage: "paperclip") }.font(.callout)
        }
    }
}

struct InlineThread: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let root: Message
    let focus: Bool
    let onHide: () -> Void
    @State private var all = false

    var body: some View {
        let replies = model.derive.threadReplies(group, root.id)
        let shown = all ? replies : Array(replies.suffix(3))
        let hidden = replies.count - shown.count
        VStack(alignment: .leading, spacing: 8) {
            if hidden > 0 {
                Button("Show \(hidden) earlier \(hidden == 1 ? "reply" : "replies")") { withAnimation { all = true } }
                    .font(.caption.weight(.semibold))
            }
            ForEach(shown) { r in
                HStack(alignment: .top, spacing: 8) {
                    Avatar(pubkey: r.ev.pubkey, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.name(r.ev.pubkey)).font(.caption.weight(.semibold))
                            Text(Format.time(r.ev.createdAt)).font(.caption2).foregroundStyle(.secondary)
                            if let p = model.pending(r.id) { Text(p.stateText).font(.caption2).foregroundStyle(p.status == .failed ? .red : .secondary) }
                        }
                        if !r.text.isEmpty { MarkdownText(text: r.text).font(.subheadline) }
                        ForEach(r.media, id: \.url) { MediaView(media: $0) }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Composer(placeholder: replies.isEmpty ? "Reply (starts a thread)" : "Reply in the thread", compact: true, autoFocus: focus) { text, _, _ in
                model.reply(text, in: group, to: root)
            }
            Button("Hide", action: onHide).font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { Rectangle().fill(Color.bronze.opacity(0.5)).frame(width: 2).padding(.vertical, 8) }
        .padding(.leading, 56)
        .padding(.trailing)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread")
    }
}

struct ThreadActivity: View {
    @EnvironmentObject var model: AppModel
    let root: Message
    let last: Message
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.name(last.ev.pubkey)) replied to \(model.name(root.ev.pubkey)): “\(snip(root.text, 80))”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(snip(last.text.isEmpty ? "a photo" : last.text, 140)).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                }
                Spacer(minLength: 0)
                Text(Format.time(last.ev.createdAt)).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.leading, 46)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityHint(open ? "Hides the thread" : "Shows the thread")
    }

    func snip(_ t: String, _ n: Int) -> String {
        let s = Mentions.npubInText.replace(t, with: "@…")
        return s.count > n ? String(s.prefix(n)) + "…" : s
    }
}

struct JoinLine: View {
    @EnvironmentObject var model: AppModel
    let join: GuestJoin
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right").foregroundStyle(Color.bronze)
            Text(join.by.map { "**\(model.name(join.pubkey))** joined as a guest, invited by **\(model.name($0))**" } ?? "**\(model.name(join.pubkey))** joined as a guest")
                .font(.footnote)
            Spacer(minLength: 0)
            Text(Format.time(join.at)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyChannel: View {
    let name: String
    let invite: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Text("\(name) is new").font(.title3.bold())
            Text("No messages yet. Bring the people who belong here, then say hi.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Invite people", action: invite).buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

// ---- composer ----------------------------------------------------------------------------------------

struct Composer: View {
    @EnvironmentObject var model: AppModel
    var placeholder = "Message"
    var canAnnounce = false
    var compact = false
    var autoFocus = false
    let onSend: (String, [Attachment], Bool) -> Void
    @State private var text = ""
    @State private var picked = [(name: String, pubkey: String)]()
    @State private var photos = [PhotosPickerItem]()
    @State private var attachments = [Attachment]()
    @State private var announce = false
    @State private var sent = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(suggestions, id: \.0) { pk, name in
                            Button { pick(pk, name) } label: {
                                HStack(spacing: 6) { Avatar(pubkey: pk, size: 22); Text(name).font(.subheadline) }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Mention \(name)")
                        }
                    }.padding(.horizontal, 2)
                }
            }
            if announce {
                HStack {
                    Label("Announcement: sent to the channel and e-mailed to its followers", systemImage: "megaphone").font(.caption)
                    Spacer()
                    Button { announce = false } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Not an announcement")
                }.foregroundStyle(Color.bronze)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
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
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !compact {
                    Menu {
                        PhotosPicker(selection: $photos, maxSelectionCount: 6, matching: .images) { Label("Photos", systemImage: "photo") }
                        if canAnnounce { Button { announce = true } label: { Label("An announcement", systemImage: "megaphone") } }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Add photos or an announcement")
                }
                TextField(announce ? "Announcement" : placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, compact ? 0 : 12)
        .padding(.vertical, compact ? 0 : 8)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.bar))
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
        .onAppear { if autoFocus { focused = true } }
        .onChange(of: photos) { _, items in load(items) }
    }

    var suggestions: [(String, String)] {
        guard let q = Mentions.query(beforeCaret: text)?.lowercased() else { return [] }
        return model.profiles.compactMap { pk, p -> (String, String)? in
            guard pk != model.me, let n = p.name, n.lowercased().split(separator: " ").contains(where: { $0.hasPrefix(q) }) else { return nil }
            return (pk, n)
        }.sorted { $0.1 < $1.1 }.prefix(6).map { $0 }
    }

    func pick(_ pk: String, _ name: String) {
        guard let q = Mentions.query(beforeCaret: text) else { return }
        text = String(text.dropLast(q.count + 1)) + "@" + name + " "
        picked.append((name, pk))
    }

    func send() {
        let t = Mentions.substitute(text.trimmingCharacters(in: .whitespacesAndNewlines), picked: picked)
        guard !t.isEmpty || !attachments.isEmpty else { return }
        onSend(t, attachments, canAnnounce && announce)
        text = ""
        picked = []
        attachments = []
        announce = false
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
