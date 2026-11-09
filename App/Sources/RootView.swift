import BelfryCore
import SwiftUI

// NavigationSplitView: channels (and Messages) in the sidebar, the open channel or conversation
// as the detail. On iPhone it collapses into a stack with swipe-back.

enum SidebarItem: Hashable {
    case channel(String)
    case messages
}

struct SearchTarget: Hashable { let channel: String; let message: String }

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem?
    @State private var query = ""
    @State private var newChannel = false
    @State private var account = false
    @State private var focus: SearchTarget?
    @State private var visibility = NavigationSplitViewVisibility.automatic
    @State private var path = [ConvRoute]()

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
                path = [ConvRoute(conv: conv)]
            }
        }
        .onChange(of: selection) { _, _ in path = [] }
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
                Section("Channels") {
                    ForEach(model.groups.filter { $0.type != .pod && $0.type != .proposal || $0.members.contains(model.me) }) { g in
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
        case "feed", "thread", "details", "invite", "actions": selection = .channel(generalId)
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
            Text(group.icon)
                .font(.title3.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
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
        Mentions.npubInText.replace(t, with: "@…").replacingOccurrences(of: "\n", with: " ")
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let _ = model.version
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
        Section(hits.isEmpty ? "Nothing found" : "\(hits.count == 200 ? "200+" : String(hits.count)) results") {
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
                            Text(m.text).font(.subheadline).lineLimit(3).foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    struct Hit: Identifiable { let channel: String; let message: Message; var id: String { message.id } }

    func results(_ words: [String]) -> [Hit] {
        guard !words.isEmpty else { return [] }
        var out = [Hit]()
        for g in model.groups {
            for m in model.derive.messages(g.id) {
                let hay = fold("\(m.text) \(model.name(m.ev.pubkey)) \(m.media.compactMap(\.name).joined(separator: " "))")
                if words.allSatisfy({ hay.contains($0) }) { out.append(Hit(channel: g.id, message: m)) }
            }
        }
        return Array(out.sorted { $0.message.ev.createdAt > $1.message.ev.createdAt }.prefix(200))
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

struct AccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Avatar(pubkey: model.me, size: 56)
                        VStack(alignment: .leading) {
                            Text(model.realName(model.me).isEmpty ? "You" : model.realName(model.me)).font(.headline)
                            Text(model.profiles[model.me]?.nip05 ?? model.config.domain).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Community") {
                    LabeledContent("Name", value: model.config.name)
                    LabeledContent("Address", value: model.config.domain)
                    if let n = Bech32.npub(model.me) {
                        LabeledContent("Your key") { Text(String(n.prefix(16)) + "…").font(.caption.monospaced()) }
                    }
                }
                Section {
                    Button(model.isDemo ? "Leave the demo" : "Sign out", role: .destructive) { confirm = true }
                } footer: {
                    Text("Signing out removes this belfry's messages from this phone. Your key stays on the belfry.")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of \(model.config.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { dismiss(); model.signOut() }
            }
        }
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
