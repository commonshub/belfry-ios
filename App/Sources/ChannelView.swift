import BelfryCore
import PhotosUI
import SwiftUI

// A channel: its name with ONE summary line under it (tap: the pull-down), the feed (day
// separators, blocks per author, cards, reactions, inline threads, resurfaced threads, join
// lines), the composer. Holding a message opens its menu (a Discord-style list).

struct ThreadRoute: Hashable { let group: String; let root: String; var reply = false }

struct ChannelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let id: String
    var focus: String?
    @State private var openThreads = Set<String>()
    @State private var pullDown = false
    @State private var details = false
    @State private var invite = false
    @State private var search = false
    @State private var didLaunch = false
    @State private var pendingThreadLaunch = false
    @State private var topic: String?
    @State private var actionsFor: Message?
    @State private var editing: Message?
    @State private var flash: String?
    @State private var scrollTarget: String?
    @State private var thread: ThreadRoute?
    @State private var podAsk = false

    var body: some View {
        let _ = model.version
        let d = model.derive
        let g = model.group(id)
        let rows = d.feedRows(id, topic: topic, openThreads: openThreads)
        let threads = d.threadsOf(id)
        let reactions = d.reactions(id)
        let todos = d.todosBySource(id)
        let pinnedIds = Set(d.pinned(id).map(\.id))
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        EmptyChannel(name: g?.name ?? id, filtered: topic != nil) { invite = true }
                    }
                    ForEach(rows) { row in
                        if row.newDay { DaySeparator(at: row.item.at) }
                        switch row.item {
                        case .message(let m):
                            MessageRow(m: m, group: id, first: row.first, reactions: reactions[m.id] ?? [], thread: threads[m.id],
                                       threadOpen: openThreads.contains(m.id), announce: row.announcement,
                                       todo: todos[m.id], pinned: pinnedIds.contains(m.id), openTopic: topic, flash: flash == m.id,
                                       onThread: { toggle(m.id) }, onOpenThread: { thread = ThreadRoute(group: id, root: m.id) },
                                       onReply: { thread = ThreadRoute(group: id, root: m.id, reply: true) },
                                       onHold: { actionsFor = m }, onTopic: { t in withAnimation { topic = t } })
                                .id(m.id)
                            if openThreads.contains(m.id) {
                                InlineThread(group: id, root: m, onOpen: { thread = ThreadRoute(group: id, root: m.id) },
                                             onHold: { actionsFor = $0 }) { toggle(m.id) }
                            }
                        case .join(let j):
                            JoinLine(join: j)
                        case .activity(let root, let last):
                            let key = "act:" + root.id
                            ThreadActivity(root: root, last: last, open: openThreads.contains(key)) { toggle(key) }
                            if openThreads.contains(key) {
                                InlineThread(group: id, root: root, onOpen: { thread = ThreadRoute(group: id, root: root.id) },
                                             onHold: { actionsFor = $0 }) { toggle(key) }
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
                if let focus { jump(to: focus, proxy) }
                applyLaunch()
                if pendingThreadLaunch { openBusiestThread(proxy) }
            }
            .onChange(of: rows.count) { _, _ in
                if focus == nil && scrollTarget == nil { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                if pendingThreadLaunch { openBusiestThread(proxy) }
            }
            .onChange(of: scrollTarget) { _, t in if let t { jump(to: t, proxy); scrollTarget = nil } }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ChannelLineBar(id: id, topic: topic, open: { pullDown = true }, showAll: { withAnimation { topic = nil } },
                                   review: { details = true })
                    if let g, g.isPod, !g.members.contains(model.me), !g.admins.contains(model.me) {
                        PodJoinBar(group: g, asked: g.applications.contains { $0.pubkey == model.me }) { podAsk = true }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Composer(group: id, placeholder: "Message \(g.map { $0.isPod ? $0.name : "#" + $0.name } ?? id)", canAnnounce: d.canAdmin(g), topic: topic) { text, attachments, announce in
                    model.post(text, in: id, attachments: attachments, announce: announce, topic: topic)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Button { pullDown = true } label: {
                    HStack(spacing: 6) {
                        if let g { ChannelGlyph(group: g, size: 18) }
                        Text(g?.name ?? id).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("\(g?.name ?? id). Show what's going on in this channel.")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { search = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search")
                Button { invite = true } label: { Image(systemName: "person.badge.plus") }.accessibilityLabel("Invite people")
            }
        }
        .navigationDestination(item: $thread) { r in ThreadView(group: r.group, rootId: r.root, focusReply: r.reply) }
        .sheet(isPresented: $pullDown) {
            PullDownSheet(id: id, topic: $topic, openDetails: { pullDown = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { details = true } },
                          showMessage: { mid in pullDown = false; scrollTarget = mid })
        }
        .sheet(isPresented: $details) { ChannelDetails(id: id) }
        .sheet(isPresented: $invite) { InviteSheet(id: id) }
        .sheet(isPresented: $search) {
            ChannelSearch(channel: id) { gid, mid in
                search = false
                if gid == id { scrollTarget = mid } else { openChannel(gid, mid) }
            }
        }
        .sheet(item: $actionsFor) { m in
            MessageActions(m: m, group: id, onReply: { thread = ThreadRoute(group: id, root: Derive.rootOf(m.ev) ?? m.id, reply: true) },
                           onOpenThread: { thread = ThreadRoute(group: id, root: Derive.rootOf(m.ev) ?? m.id) },
                           onEdit: { editing = m })
        }
        .sheet(item: $editing) { m in EditSheet(m: m, group: id) }
        .sheet(isPresented: $podAsk) { if let g { PodApplySheet(group: g) } }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "belfry-channel", let gid = url.pathComponents.last?.removingPercentEncoding {
                openChannel(gid, nil)
                return .handled
            }
            return .systemAction
        })
    }

    func jump(to mid: String, _ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation { proxy.scrollTo(mid, anchor: .center) }
            flash = mid
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if flash == mid { flash = nil } }
        }
    }

    /// Screenshots: unfold the thread with the most replies once the demo data is there.
    func openBusiestThread(_ proxy: ScrollViewProxy) {
        guard let root = model.derive.threadsInOrder(id).max(by: { $0.info.count < $1.info.count })?.root else { return }
        pendingThreadLaunch = false
        openThreads.insert(root)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(root, anchor: .top) }
    }

    func toggle(_ key: String) {
        withAnimation(.snappy) {
            if openThreads.contains(key) { openThreads.remove(key) } else { openThreads.insert(key) }
        }
    }

    func applyLaunch() {
        guard !didLaunch else { return }
        didLaunch = true
        switch model.launch.screen {
        case "thread": pendingThreadLaunch = true
        case "details": details = true
        case "invite": invite = true
        case "pulldown", "proposal": DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { pullDown = true }
        case "menu":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                actionsFor = model.derive.messages(id).last { $0.pubkey == model.me && model.derive.canEdit($0) }
            }
        case "delete":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                model.launchDelete = true
                actionsFor = model.derive.messages(id).last { $0.pubkey == model.me && model.derive.canEdit($0) }
            }
        case "edit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                editing = model.derive.messages(id).last { $0.pubkey == model.me && model.derive.canEdit($0) }
            }
        case "threadscreen":
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if let root = model.derive.threadsInOrder(id).max(by: { $0.info.count < $1.info.count })?.root { thread = ThreadRoute(group: id, root: root) }
            }
        case "chsearch": DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { search = true }
        case "add": DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { model.launchAdd = true }
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
        if Calendar.current.component(.year, from: d) != Calendar.current.component(.year, from: Date()) {
            return d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        }
        return d.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func time(_ at: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(at)).formatted(date: .omitted, time: .shortened)
    }

    static func ago(_ at: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(at)).formatted(.relative(presentation: .named))
    }

    static func short(_ at: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(at))
        if Calendar.current.isDateInToday(d) { return time(at) }
        return d.formatted(.dateTime.day().month(.abbreviated))
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
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(s.width, bounds.width), height: s.height))
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

struct EmptyChannel: View {
    let name: String
    var filtered = false
    let invite: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            if filtered {
                Text("Nothing with this topic yet").font(.title3.bold())
            } else {
                Text("\(name) is new").font(.title3.bold())
                Text("No messages yet. Bring the people who belong here, then say hi.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Invite people", action: invite).buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}

/// Under a pod's name for someone not in it: Join (open) or Ask to join (closed).
struct PodJoinBar: View {
    @EnvironmentObject var model: AppModel
    let group: Channel
    let asked: Bool
    let ask: () -> Void
    var body: some View {
        HStack {
            Text(asked ? "You asked to join. Its members will answer." : group.closed ? "Joining takes an application." : "You're not in this pod.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            if !asked {
                if group.closed {
                    Button("Ask to join", action: ask).buttonStyle(.borderedProminent).controlSize(.small)
                } else {
                    BusyButton("Join") { model.join(group.id) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}

/// Asking to join a closed pod: the pod's question and an answer.
struct PodApplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let group: Channel
    @State private var answer = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(group.prompt ?? Actions.defaultPrompt).font(.headline)
                    TextField("Your answer", text: $answer, axis: .vertical).lineLimit(3...8).font(.body)
                } footer: { Text("Its members see your answer and let you in.") }
            }
            .navigationTitle("Ask to join \(group.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Send") { model.apply(group.id, answer: answer.jsTrim()); dismiss() }
                        .disabled(answer.jsTrim().isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
