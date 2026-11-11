import BelfryCore
import SwiftUI

// NavigationSplitView: channels (and Messages) in the sidebar, the open channel or conversation
// as the detail. On iPhone it collapses into a stack with swipe-back.

enum SidebarItem: Hashable {
    case channel(String)
    case messages
}

struct SearchTarget: Hashable { let channel: String; let message: String }
struct EventKey: Identifiable { let key: String; var id: String { key } }

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem?
    @State private var query = ""
    @State private var newChannel = false
    @State private var account = false
    @State private var focus: SearchTarget?
    @State private var visibility = NavigationSplitViewVisibility.automatic
    @State private var path = NavigationPath()

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                switch selection {
                case .channel(let id): ChannelView(id: id, focus: focus?.channel == id ? focus?.message : nil).id(id)
                case .messages: MessagesView()
                case nil: ContentUnavailableView("Pick a channel", systemImage: "number", description: Text("Your community's channels are on the left."))
                }
            }
            .environment(\.openConversation) { conv in
                var p = NavigationPath()
                p.append(ConvRoute(conv: conv))
                path = p
            }
        }
        .environment(\.openChannel) { id, message in
            focus = message.map { SearchTarget(channel: id, message: $0) }
            if selection == .channel(id) { path = NavigationPath() } else { selection = .channel(id) }
        }
        .onChange(of: selection) { _, _ in path = NavigationPath() }
        .onChange(of: model.messageAuthor) { _, pk in
            guard let pk else { return }
            model.messageAuthor = nil
            selection = .messages
            let conv = MailThreads.nostrConv(author: pk, pTags: [], me: model.me)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var p = NavigationPath()
                p.append(ConvRoute(conv: conv))
                path = p
            }
        }
        .sheet(item: Binding(get: { model.openEvent.map { EventKey(key: $0) } }, set: { model.openEvent = $0?.key })) { k in
            EventPage(key: k.key)
        }
        .sheet(item: Binding(get: { model.showEvents.map { EventKey(key: $0) } }, set: { model.showEvents = $0?.key })) { k in
            EventsList(channel: k.key.isEmpty ? nil : k.key)
        }
        .sheet(item: Binding(get: { model.openProfile.map { ProfileKey(pubkey: $0) } }, set: { model.openProfile = $0?.pubkey })) { k in
            ProfileView(pubkey: k.pubkey)
        }
        .sheet(item: Binding(get: { model.pendingInvite }, set: { if $0 == nil { model.pendingInvite = nil } })) { inv in
            JoinWithAccountSheet(invite: inv)
        }
        .onChange(of: model.joinedChannel) { _, id in
            guard let id else { return }
            model.joinedChannel = nil
            selection = .channel(id)
        }
        .alert(model.website ?? "", isPresented: Binding(get: { model.website != nil }, set: { if !$0 { model.website = nil } })) {
            Button("OK") { model.website = nil }
        }
        .onAppear(perform: applyLaunchScreen)
        .sheet(isPresented: $newChannel) { NewChannelSheet { id in selection = .channel(id) } }
        .sheet(isPresented: $account) { AccountSheet() }
    }

    private var sidebar: some View {
        let _ = model.version
        return List(selection: $selection) {
            if !query.isEmpty {
                SearchResults(query: query) { target in
                    focus = target
                    selection = .channel(target.channel)
                }
            } else {
                if model.access == .denied {
                    Section {
                        Label("This belfry doesn't let your key in yet. Ask an admin, or check your membership.", systemImage: "lock")
                            .font(.callout)
                    }
                }
                Section {
                    NavigationLink(value: SidebarItem.messages) {
                        Label {
                            HStack {
                                Text("Messages")
                                Spacer()
                                if model.unreadDMs > 0 {
                                    Text("\(model.unreadDMs)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Color.bronze, in: Capsule())
                                        .foregroundStyle(.white)
                                        .accessibilityLabel("\(model.unreadDMs) unread")
                                }
                            }
                        } icon: { Image(systemName: "envelope") }
                    }
                }
                Section("Events") {
                    Button { model.showEvents = "" } label: { Label("All events", systemImage: "calendar") }
                    ForEach(model.derive.yourEvents(now: .now)) { e in
                        NavigationLink(value: SidebarItem.channel(e.groupId)) {
                            HStack(spacing: 10) {
                                DateChip(at: e.start).scaleEffect(0.8).frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title).lineLimit(1)
                                    Text(model.derive.stateLabel(e) ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Section("Channels") {
                    ForEach(model.groups.filter { $0.type == .channel || ($0.isPod || $0.isProposal) && $0.members.contains(model.me) }) { g in
                        NavigationLink(value: SidebarItem.channel(g.id)) { ChannelRow(group: g) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(model.config.name)
        .searchable(text: $query, placement: .sidebar, prompt: "Search all channels")
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { account = true } label: { Avatar(pubkey: model.me, size: 30) }
                    .accessibilityLabel("Your account")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newChannel = true } label: { Image(systemName: "plus.bubble") }
                    .accessibilityLabel("New channel")
            }
            ToolbarItem(placement: .bottomBar) { ConnectionBadge() }
        }
    }

    private func applyLaunchScreen() {
        switch model.launch.screen {
        case "feed", "thread", "details", "invite", "actions", "pulldown", "menu", "delete", "edit", "threadscreen", "chsearch", "add": selection = .channel(generalId)
        case "pod": selection = .channel("pod-seed-swap-5e1d")
        case "profile":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openProfile = Demo.signer("ana").pubkey }
        case "editprofile", "me":
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { account = true }
        case "members", "todos", "files": selection = .channel(generalId)
        case "proposal": selection = .channel("prop-quiet-hours-after-22-00-7f3a2b")
        case "events": DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.showEvents = "" }
        case "eventhost":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "2026-gwday1" }
        case "eventform":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.launchEventForm = true }
        case "event":
            selection = .channel(generalId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.openEvent = "repair-cafe" }
        case "messages", "conversation", "mail": selection = .messages
        case "search": query = "ladder"
        default: break
        }
    }
}

struct ChannelRow: View {
    @EnvironmentObject var model: AppModel
    let group: Channel

    var body: some View {
        let last = model.derive.messages(group.id).last
        HStack(spacing: 12) {
            ChannelGlyph(group: group, size: 22)
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.body.weight(.medium)).lineLimit(1)
                if let last {
                    Text("\(model.name(last.ev.pubkey)): \(preview(last.text))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.name) channel")
    }

    func preview(_ t: String) -> String {
        let plain = Rx("\\*\\*|__|~~|`").replace(t, with: "")
        return model.derive.plainRefs(plain).replacingOccurrences(of: "\n", with: " ")
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let _ = model.version
        status.labelStyle(.titleAndIcon)
    }

    @ViewBuilder var status: some View {
        if model.isDemo {
            Label("Demo: nothing leaves this phone", systemImage: "iphone").font(.caption).foregroundStyle(.secondary)
        } else if !model.online {
            Label("Offline: messages wait on this phone", systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary)
        } else if model.engine?.relaysUp != true {
            Label("Connecting…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }
}

struct SearchResults: View {
    @EnvironmentObject var model: AppModel
    let query: String
    let open: (SearchTarget) -> Void

    var body: some View {
        let words = fold(query).split(separator: " ").map(String.init)
        let hits = results(words)
        Section(hits.isEmpty ? "Nothing found" : "\(hits.count == 200 ? "200+" : String(hits.count)) \(hits.count == 1 ? "result" : "results")") {
            ForEach(hits) { hit in
                let gid = hit.channel, m = hit.message
                Button { open(SearchTarget(channel: gid, message: m.id)) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(pubkey: m.ev.pubkey, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(model.name(m.ev.pubkey)).font(.subheadline.bold())
                                Text("\(model.group(gid)?.icon ?? "#")\(model.group(gid)?.name ?? gid)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(model.derive.plainRefs(m.text)).font(.subheadline).lineLimit(3).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    struct Hit: Identifiable { let channel: String; let message: Message; var id: String { message.id } }

    func results(_ words: [String]) -> [Hit] {
        guard !words.isEmpty else { return [] }
        return model.derive.search(query).map { Hit(channel: $0.groupId, message: $0.m) }
    }
}

struct NewChannelSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var about = ""
    let created: (String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                TextField("What is it about?", text: $about, axis: .vertical).lineLimit(2...5)
            }
            .navigationTitle("New channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let id = model.createChannel(name: name.trimmingCharacters(in: .whitespaces), about: about.trimmingCharacters(in: .whitespaces))
                        dismiss()
                        created(id)
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct Avatar: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    var size: CGFloat = 36

    var body: some View {
        let p = model.profiles[pubkey]
        let name = Derive.realName(pubkey, model.profiles)
        ZStack {
            Circle().fill(color)
            if let pic = p?.picture, let url = URL(string: pic), pic.hasPrefix("https://") {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { initials(name) }
                    .clipShape(Circle())
            } else {
                initials(name)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    func initials(_ name: String) -> some View {
        Text(String((name.isEmpty ? "?" : name).prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
    }

    var color: Color {
        let palette: [Color] = [.bronze, .teal, .indigo, .orange, .pink, .green, .purple, .brown]
        let n = pubkey.utf8.prefix(6).reduce(0) { $0 &+ Int($1) }
        return palette[n % palette.count]
    }
}
