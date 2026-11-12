import BelfryCore
import PhotosUI
import SwiftUI

// Profiles (SPEC 19.5, 19.16): picture, name, address, about, tags, place, guest / agent chips,
// shared channels, Message; Make it my agent / Remove; the admin switch. Edit my profile
// (username through the belfry, picture ≤ 512 px, tags with suggestions, place from the belfry's
// list). Me: my card, address, key, signed-in devices, outbox, sign out.

struct ProfileKey: Identifiable { let pubkey: String; var id: String { pubkey } }

struct ProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openChannel) private var openChannel
    let pubkey: String
    @State private var edit = false
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        let _ = model.version
        let d = model.derive
        let p = d.profiles()[pubkey]
        let x = d.extras[pubkey]
        let me = pubkey == model.me
        let joins = d.guestJoinsOf(pubkey)
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Avatar(pubkey: pubkey, size: 88)
                        Text(me ? (model.realName(pubkey).isEmpty ? "You" : model.realName(pubkey)) : model.name(pubkey)).font(.title2.bold())
                        if let n5 = p?.nip05, n5.contains("@") { Text(n5).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled) }
                        FlowRow(spacing: 6) {
                            if let owner = d.agentOwner(pubkey) {
                                Chip(text: "agent", tint: .bronze)
                                Chip(text: owner == model.me ? "agent of you" : "agent of \(model.realNameOrKey(owner))")
                            } else {
                                ForEach(Array(Set(joins.compactMap(\.chip))).sorted(), id: \.self) { Chip(text: $0, tint: .bronze) }
                            }
                            if d.isBelfryAdmin(pubkey) { Chip(text: "admin of the belfry") }
                        }
                        if !me && !d.isGuest(model.me) {
                            Button { dismiss(); model.messageAuthor = pubkey } label: { Label("Message", systemImage: "envelope") }
                                .buttonStyle(.borderedProminent)
                        }
                        if me { Button("Edit profile") { edit = true }.buttonStyle(.bordered) }
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
                if let about = p?.about, !about.isEmpty { Section("About") { MarkdownText(text: about) } }
                if let x, !x.tags.isEmpty {
                    Section("Tags") { FlowRow(spacing: 6) { ForEach(x.tags, id: \.self) { Chip(text: "#" + $0) } } }
                }
                if let place = x?.place { Section("Where") { Label(People.placeLabel(place), systemImage: "mappin.and.ellipse") } }
                let shared = d.sharedGroups(pubkey)
                if !shared.isEmpty {
                    Section("Channels") {
                        ForEach(shared) { g in
                            Button { dismiss(); openChannel(g.id, nil) } label: {
                                HStack(spacing: 10) { ChannelGlyph(group: g, size: 18); Text(g.name) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !me {
                    Section {
                        if model.mayMakeMine(pubkey) {
                            ActionButtonRow(icon: "person.badge.key", title: "Make it my agent", detail: "It joins as yours: it stays while you do.") {
                                error = await model.setMyAgent(pubkey, mine: true)
                            }
                        }
                        if let owner = d.agentOwner(pubkey), owner == model.me || d.isCommunityAdmin {
                            Button { confirmRemove = true } label: { ActionRow(icon: "person.badge.minus", title: "Remove this agent…", destructive: true) }
                        }
                        if d.isCommunityAdmin && d.agentOwner(pubkey) == nil {
                            AdminSwitch(pubkey: pubkey) { error = $0 }
                        }
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $edit) { EditProfileView() }
            .confirmationDialog("Remove this agent?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { error = await model.setMyAgent(pubkey, mine: false) } }
            } message: { Text("It is taken out of every channel. This can't be undone.") }
            .task {
                await model.revalidateConfig()
                await model.askWhois([pubkey])
            }
        }
    }
}

/// "Admin of the belfry" (SPEC 19.5): disabled with the reason for an agent or an unsaved guest.
struct AdminSwitch: View {
    @EnvironmentObject var model: AppModel
    let pubkey: String
    let report: (String?) -> Void
    @State private var busy = false

    var body: some View {
        let on = model.derive.isBelfryAdmin(pubkey)
        let reason = on ? nil : model.derive.noAdminReason(pubkey)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { on }, set: { v in
                guard !busy else { return }
                busy = true
                Task { report(await model.setAdmin(pubkey, v)); busy = false }
            })) {
                HStack { Text("Admin of the belfry"); if busy { ProgressView().controlSize(.small) } }
            }
            .disabled(busy || reason != nil)
            if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct EditProfileView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var about = ""
    @State private var tags = [String]()
    @State private var newTag = ""
    @State private var share: Share = .city
    @State private var place: Place?
    @State private var photo: PhotosPickerItem?
    @State private var picture: Data?
    @State private var error: String?
    @State private var loaded = false
    @State private var placePicker = false

    var body: some View {
        let d = model.derive
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photo, matching: .images) {
                            VStack {
                                if let picture, let img = UIImage(data: picture) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 80, height: 80).clipShape(Circle())
                                } else {
                                    Avatar(pubkey: model.me, size: 80)
                                }
                                Text("Change picture").font(.caption)
                            }
                        }
                        Spacer()
                    }
                }
                Section("Name") { TextField("Your name", text: $name).font(.body) }
                Section {
                    HStack(spacing: 2) {
                        TextField("username", text: $username).font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("@" + model.config.domain).foregroundStyle(.secondary)
                    }
                } header: { Text("Username") } footer: { Text("Your address here, and your e-mail address.") }
                Section("About") { TextField("A few words about you (Markdown)", text: $about, axis: .vertical).lineLimit(3...8).font(.body) }
                Section("Tags") {
                    if !tags.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(tags, id: \.self) { t in
                                Button { tags.removeAll { $0 == t } } label: { Chip(text: "#" + t, icon: "xmark", tint: .bronze) }.buttonStyle(.plain)
                                    .accessibilityLabel("Remove \(t)")
                            }
                        }
                    }
                    HStack {
                        TextField("Add a tag", text: $newTag).font(.body).textInputAutocapitalization(.never).onSubmit(addTag)
                        Button("Add", action: addTag).disabled(People.cleanTag(newTag).isEmpty)
                    }
                    let suggestions = d.allTags.map(\.tag).filter { !tags.contains($0) && (newTag.isEmpty || $0.hasPrefix(People.cleanTag(newTag))) }.prefix(8)
                    if !suggestions.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(Array(suggestions), id: \.self) { t in
                                Button { tags = People.cleanTags(tags + [t]) } label: { Chip(text: "+ #" + t) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Section {
                    Picker("Show", selection: $share) {
                        Text("My city").tag(Share.city)
                        Text("Only my country").tag(Share.country)
                        Text("Nothing").tag(Share.none)
                    }
                    if share != .none {
                        Button { placePicker = true } label: {
                            ActionRow(icon: "mappin.and.ellipse", title: place.map { share == .country ? People.countryName($0.country) : People.placeLabel($0) } ?? "Pick a place")
                        }
                    }
                } header: { Text("Where you are") } footer: { Text("Picked from a list of cities, never from your phone's location.") }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { BusyButton("Save") { await save() }.disabled(name.jsTrim().isEmpty) }
            }
            .sheet(isPresented: $placePicker) { PlacePicker { place = $0 } }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { picture = Images.jpeg(data, max: 512) }
                }
            }
            .onAppear(perform: load)
        }
    }

    var currentUsername: String {
        let n5 = model.derive.profiles()[model.me]?.nip05 ?? ""
        return String(n5.split(separator: "@").first ?? "")
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        let d = model.derive
        name = model.realName(model.me)
        about = d.aboutOf(model.me)
        username = currentUsername
        if let x = d.extras[model.me] {
            tags = x.tags
            share = x.share
            place = x.place
        }
    }

    func addTag() {
        tags = People.cleanTags(tags + [newTag])
        newTag = ""
    }

    func save() async {
        error = nil
        if username.jsTrim().lowercased() != currentUsername, !username.jsTrim().isEmpty {
            if let e = await model.setUsername(username) { error = e; return }
        }
        if let e = await model.saveProfile(name: name, about: about, picture: picture) { error = e; return }
        model.saveExtras(tags: tags, share: share, place: share == .none ? nil : place)
        dismiss()
    }
}

/// A city from the belfry's list (GET /places), a place a member adds, or a country only.
struct PlacePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pick: (Place) -> Void
    @State private var query = ""
    @State private var results = [Place]()
    @State private var adding = false
    @State private var newName = ""
    @State private var near: Place?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if adding {
                    Section {
                        TextField("The place's name", text: $newName).font(.body)
                        Text(near.map { "Near \(People.placeLabel($0))" } ?? "Search the nearest city above, then pick it").font(.caption).foregroundStyle(.secondary)
                        BusyButton("Add the place") {
                            guard let near else { return }
                            switch await model.addPlace(name: newName.jsTrim(), country: near.country, near: near.placeId ?? "") {
                            case .success(let p): pick(p); dismiss()
                            case .failure(let e): error = e.message
                            }
                        }
                        .disabled(newName.jsTrim().isEmpty || near == nil)
                    }
                }
                Section {
                    ForEach(results) { p in
                        Button {
                            if adding { near = p } else { pick(p); dismiss() }
                        } label: { ActionRow(icon: "mappin", title: p.name ?? p.country, detail: [p.region, People.countryName(p.country)].compactMap { $0 }.joined(separator: ", ")) }
                    }
                }
                if !adding {
                    Section { Button { adding = true } label: { ActionRow(icon: "plus", title: "My place is not in the list") } }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: adding ? "Nearest city" : "City")
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 300_000_000)
                results = await model.searchPlaces(query)
            }
            .navigationTitle("Where you are")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Me: my card (edit), address, key, signed-in devices, the outbox, sign out.
struct AccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm = false
    @State private var edit = false
    @State private var copied = false

    var body: some View {
        let _ = model.version
        let queued = model.engine?.outboxItems() ?? []
        NavigationStack {
            List {
                Section {
                    Button { edit = true } label: {
                        HStack(spacing: 14) {
                            Avatar(pubkey: model.me, size: 56)
                            VStack(alignment: .leading) {
                                Text(model.realName(model.me).isEmpty ? "You" : model.realName(model.me)).font(.headline)
                                Text(model.derive.myAddress ?? model.config.domain).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Edit").font(.subheadline).foregroundStyle(Color.bronze)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if model.unsavedGuest {
                    Section { SaveAccountCard() }
                }
                Section("Community") {
                    LabeledContent("Name", value: model.config.name)
                    LabeledContent("Address", value: model.config.domain)
                    if let n = Bech32.npub(model.me) {
                        Button {
                            UIPasteboard.general.string = n
                            copied = true
                        } label: {
                            LabeledContent("Your key") { Text(copied ? "Copied" : String(n.prefix(16)) + "…").font(.caption.monospaced()) }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    NavigationLink { NotificationsView() } label: {
                        ActionRow(icon: "bell", title: "Notifications", detail: model.pushState == .on ? "On" : model.pushState == .denied ? "Off in Settings" : "Turn on")
                    }
                    NavigationLink { DevicesView() } label: { ActionRow(icon: "iphone", title: "Signed-in devices") }
                    if !queued.isEmpty {
                        ActionRow(icon: "tray.and.arrow.up", title: "\(queued.count) waiting to be sent",
                                  detail: queued.contains { $0.status == .failed } ? "Some could not be sent: Retry or Discard them where they are" : nil)
                    }
                }
                Section {
                    Button(model.isDemo ? "Leave the demo" : "Sign out", role: .destructive) { confirm = true }
                } footer: {
                    Text("Signing out ends this phone's session and removes this belfry's messages from it. Your key stays on the belfry.")
                }
            }
            .navigationTitle("You")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of \(model.config.name)?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { dismiss(); Task { await model.signOutEverywhere() } }
            }
            .sheet(isPresented: $edit) { EditProfileView() }
            .onAppear { if model.launch.screen == "editprofile" { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { edit = true } } }
        }
    }
}

/// Signed-in devices: the sessions open on my key; end one (this device is marked).
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var list: [SessionInfo]?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            if let list {
                ForEach(list) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.applicationName.isEmpty ? "An app" : s.applicationName).font(.subheadline.weight(.semibold))
                            Text([s.device, s.lastActivity.map { "last used " + $0.prefix(10) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if s.bunkerPubkey == model.mySessionKey {
                            Text("This device").font(.caption).foregroundStyle(.secondary)
                        } else {
                            BusyButton("End", role: .destructive) {
                                if let e = await model.endSession(s.bunkerPubkey) { error = e } else { await load() }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Signed-in devices")
        .task { await load() }
    }

    func load() async {
        switch await model.sessions() {
        case .success(let l): list = l
        case .failure(let e): error = e.message; list = []
        }
    }
}

/// A guest who joined with a name only (an event's guest, an older link) saves their account:
/// Save opens the same sheet as joining from guest mode, with the e-mail only (SPEC 19.26).
struct SaveAccountCard: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    @State private var open = false
    @State private var savedAs: String?

    var body: some View {
        HStack(spacing: 10) {
            if let savedAs {
                Label("Saved. Sign in with \(savedAs) on any device.", systemImage: "checkmark.circle").foregroundStyle(.green)
                    .font(compact ? .caption : .subheadline)
            } else {
                Text(model.coHostToken != nil ? "To host this event, save your account with your e-mail." : "Save your account: add your e-mail to come back from any device.")
                    .font(compact ? .caption : .subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Save") { open = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .sheet(isPresented: $open) { JoinSheet(saveOnly: true) { savedAs = $0 } }
    }
}
