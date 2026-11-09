import BelfryCore
import CoreImage
import SwiftUI

// The channel's details as a sheet with medium and large detents (the web's pull-down header):
// description, who was active this month, members, photos, and settings for its admins.

struct ChannelDetails: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var editing = false
    @State private var invite = false

    var body: some View {
        let _ = model.version
        let g = model.group(id)
        let active = model.derive.recentlyActive(id)
        let photos = model.derive.messages(id).flatMap(\.media).filter { $0.mime.hasPrefix("image/") }.reversed().prefix(12)
        NavigationStack {
            List {
                Section {
                    if let p = g?.parent, let parent = model.group(p) {
                        Text("\(g?.type == .proposal ? "Proposal" : "Pod") in \(parent.icon) \(parent.name)").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let about = g?.about, !about.isEmpty { MarkdownText(text: about) } else { Text("No description yet.").foregroundStyle(.secondary) }
                    if model.derive.isInbox(g) {
                        Label("Anyone can e-mail \(id)@\(model.config.domain): mails land here as cards.", systemImage: "tray").font(.footnote)
                    } else {
                        Label("Members can e-mail \(id)@\(model.config.domain): their mail shows as their message.", systemImage: "envelope").font(.footnote)
                    }
                }
                Section(active.isEmpty ? "Nobody active this month yet" : "\(active.count) active this month") {
                    ForEach(active, id: \.pubkey) { a in
                        HStack {
                            Avatar(pubkey: a.pubkey, size: 32)
                            Text(model.name(a.pubkey))
                            Spacer()
                            Text(Format.ago(a.at)).font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if !photos.isEmpty {
                    Section("Photos") {
                        ScrollView(.horizontal) {
                            HStack { ForEach(Array(photos), id: \.url) { MediaView(media: $0).frame(width: 90, height: 90) } }
                        }
                    }
                }
                Section("Members (\(g?.members.count ?? 0))") {
                    ForEach((g?.members ?? []).sorted { model.name($0) < model.name($1) }, id: \.self) { pk in
                        HStack {
                            Avatar(pubkey: pk, size: 28)
                            Text(model.name(pk))
                            if g?.admins.contains(pk) == true { Text("admin").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    Button { invite = true } label: { Label("Invite people", systemImage: "person.badge.plus") }
                    if let g, !g.members.contains(model.me), !g.admins.contains(model.me) {
                        Button { model.join(id) } label: { Label(g.closed ? "Ask to join" : "Join", systemImage: "person.crop.circle.badge.plus") }
                    }
                    if model.derive.canAdmin(g) {
                        Button { editing = true } label: { Label("Settings", systemImage: "gearshape") }
                    }
                }
            }
            .navigationTitle("\(g?.icon ?? "#") \(g?.name ?? id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editing) { ChannelSettings(id: id) }
            .sheet(isPresented: $invite) { InviteSheet(id: id) }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ChannelSettings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var about = ""
    @State private var inbox = false
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name) }
                Section("Description") { TextField("What is it about?", text: $about, axis: .vertical).lineLimit(3...8) }
                Section {
                    Toggle("Shared inbox", isOn: $inbox)
                } footer: {
                    Text(inbox ? "Anyone can e-mail \(id)@\(model.config.domain). Mails land here as cards and the channel's admins answer as the channel."
                         : "Only members can e-mail \(id)@\(model.config.domain); their mail shows as their message.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.editChannel(id, name: name.trimmingCharacters(in: .whitespaces), about: about.trimmingCharacters(in: .whitespaces), inbox: inbox)
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard !loaded, let g = model.group(id) else { return }
                loaded = true
                name = g.name
                about = g.about
                inbox = model.derive.isInbox(g)
            }
        }
    }
}

struct InviteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var guest = false
    @State private var guestURL: String?
    @State private var error: GuestLinkError?
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        let g = model.group(id)
        let label = "\(g?.icon ?? "#") \(g?.name ?? id)"
        let link = guest ? guestURL : model.config.channelLink(id)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Toggle(isOn: $guest) {
                        VStack(alignment: .leading) {
                            Text("Guest access for 30 days").font(.headline)
                            Text("For someone who isn't a member: this channel only, nothing else.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: guest) { _, on in if on && guestURL == nil { Task { await makeGuest() } } }
                    ZStack {
                        if let link, let img = QR.image(link) {
                            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                                .accessibilityLabel("QR code of the \(guest ? "guest" : "channel") link")
                        } else {
                            RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4))
                        }
                        if busy { ProgressView().controlSize(.large) }
                        if let error, guest, guestURL == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.circle").font(.largeTitle)
                                Text(error.message).multilineTextAlignment(.center).font(.callout)
                                Button("Retry") { Task { await makeGuest() } }.buttonStyle(.bordered)
                            }
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(width: 240, height: 240)
                    Text(link ?? (busy ? "Making the guest link…" : "—"))
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button {
                            UIPasteboard.general.string = link
                            copied = true
                        } label: { Label(copied ? "Copied" : "Copy link", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                            .disabled(link == nil)
                        if let link, let url = URL(string: link) {
                            ShareLink(item: url, subject: Text(label), message: Text("Join \(label) on \(model.config.name)")) {
                                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    Text(guest ? "One person uses this link: they give their name and e-mail, and join for 30 days. Everyone here sees who invited them."
                         : "Members open \(label) with this link. For someone who isn't a member yet, turn on guest access above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Invite to \(label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sensoryFeedback(.success, trigger: copied)
        }
        .presentationDetents([.large])
    }

    func makeGuest() async {
        busy = true
        error = nil
        switch await model.guestLink(id) {
        case .success(let u): guestURL = u
        case .failure(let e): error = e
        }
        busy = false
    }
}
