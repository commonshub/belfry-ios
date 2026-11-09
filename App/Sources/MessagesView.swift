import BelfryCore
import SwiftUI

// Messages: NIP-17 conversations and e-mail threads (one per subject), SPEC 10.

struct ConvRoute: Hashable { let conv: String }

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var newOne = false
    @State private var path = [ConvRoute]()
    @State private var didLaunch = false

    var body: some View {
        let _ = model.version
        let threads = model.dms?.threads() ?? []
        List {
            if threads.isEmpty {
                ContentUnavailableView("No messages yet", systemImage: "envelope", description: Text("Write to a member, or to any e-mail address."))
            }
            ForEach(threads) { t in
                NavigationLink(value: ConvRoute(conv: t.conv)) { ThreadRow(thread: t) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Messages")
        .navigationDestination(for: ConvRoute.self) { ConversationView(conv: $0.conv) }
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newOne = true } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("New message")
            }
        }
        .sheet(isPresented: $newOne) { NewConversation() }
        .onAppear {
            guard !didLaunch else { return }
            didLaunch = true
            if model.launch.screen == "conversation" || model.launch.screen == "mail" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let list = model.dms?.threads() ?? []
                    let pick = model.launch.screen == "mail" ? list.first { MailThreads.isMail($0.conv) } : list.first { !MailThreads.isMail($0.conv) }
                    if let pick { navigate(pick.conv) }
                }
            }
        }
    }

    @Environment(\.openConversation) private var navigate
}

private struct OpenConversationKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}

extension EnvironmentValues {
    var openConversation: (String) -> Void {
        get { self[OpenConversationKey.self] }
        set { self[OpenConversationKey.self] = newValue }
    }
}

struct ThreadRow: View {
    @EnvironmentObject var model: AppModel
    let thread: DmThread

    var body: some View {
        let mail = MailThreads.isMail(thread.conv)
        HStack(alignment: .top, spacing: 12) {
            if mail {
                Image(systemName: "envelope.fill").font(.title3).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Color.bronze, in: Circle())
                    .accessibilityHidden(true)
            } else {
                Avatar(pubkey: MailThreads.peers(thread.conv).first ?? "", size: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.body.weight(thread.unread > 0 ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    Text(Format.ago(thread.last.at)).font(.caption).foregroundStyle(.secondary)
                }
                if mail { Text(model.dms?.threadName(thread.conv) ?? "").font(.subheadline.weight(.medium)).lineLimit(1) }
                Text(thread.last.mine ? "You: \(thread.last.text)" : thread.last.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            if thread.unread > 0 {
                Circle().fill(Color.bronze).frame(width: 10, height: 10).padding(.top, 6).accessibilityLabel("Unread")
            }
        }
        .accessibilityElement(children: .combine)
    }

    var title: String { convName(model, thread.conv) }
}

@MainActor func convName(_ model: AppModel, _ conv: String) -> String {
    if MailThreads.isMail(conv) {
        let a = MailThreads.address(conv)
        let named = model.dms?.threads().flatMap { model.dms?.thread($0.conv) ?? [] }.first { !$0.mine && $0.fromName != nil && MailThreads.isMail($0.conv) && MailThreads.address($0.conv) == a }?.fromName
        return named ?? a
    }
    return MailThreads.peers(conv).map(model.name).joined(separator: ", ")
}

struct ConversationView: View {
    @EnvironmentObject var model: AppModel
    let conv: String
    @State private var text = ""
    @State private var subject = ""
    @State private var error: String?
    @State private var sending = 0

    var body: some View {
        let _ = model.version
        let list = model.dms?.thread(conv) ?? []
        let mail = MailThreads.isMail(conv)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if list.isEmpty {
                    Text(mail ? "A new e-mail to \(MailThreads.address(conv)): its subject names the thread. It goes out from \(model.dms?.myAddress ?? "your address here"); answers land in the thread."
                         : "No messages yet. Only you two can read them.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
                ForEach(list) { d in Bubble(dm: d) }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(mail && !MailThreads.isNewMail(conv) ? (model.dms?.threadName(conv) ?? "") : convName(model, conv))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.dms?.markRead(conv) }
        .onChange(of: list.count) { _, _ in model.dms?.markRead(conv) }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                if MailThreads.isNewMail(conv) {
                    TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                }
                HStack(alignment: .bottom) {
                    TextField(mail ? "Write an e-mail" : "Message", text: $text, axis: .vertical)
                        .lineLimit(1...8)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.background, in: RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                }
            }
            .padding(12)
            .background(.bar)
            .sensoryFeedback(.impact(weight: .light), trigger: sending)
        }
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let dms = model.dms else { return }
        if MailThreads.isNewMail(conv), subject.trimmingCharacters(in: .whitespaces).isEmpty {
            error = "Give it a subject: it names the thread."
            return
        }
        error = nil
        text = ""
        sending += 1
        Task {
            do {
                if MailThreads.isMail(conv) {
                    try await dms.sendMail(t, in: conv, subject: subject, fromName: model.realName(model.me))
                } else {
                    try await dms.send(t, in: conv)
                }
            } catch {
                text = t
                self.error = (error as? BelfryError)?.errorDescription ?? "Not sent. Try again."
            }
        }
    }
}

struct Bubble: View {
    @EnvironmentObject var model: AppModel
    let dm: Dm

    var body: some View {
        let report = model.dms?.report(dm.emailId)
        VStack(alignment: dm.mine ? .trailing : .leading, spacing: 4) {
            if !dm.mine, dm.kind == 1301 {
                HStack(spacing: 4) {
                    Text(dm.fromName ?? dm.from).font(.caption.weight(.semibold))
                    if dm.verified == true { Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green).accessibilityLabel("Verified sender") }
                }
            }
            if dm.kind == 1301, let s = dm.subject { Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            MarkdownText(text: dm.text.isEmpty ? " " : dm.text)
                .padding(10)
                .background(dm.mine ? Color.bronze.opacity(0.16) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 6) {
                Text(Format.time(dm.at)).font(.caption2).foregroundStyle(.secondary)
                if let f = dm.failed {
                    Label("Not sent", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.red).help(f)
                    Button("Retry") { model.dms?.retry(dm) }.font(.caption2.weight(.semibold))
                } else if dm.pending == true {
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                } else if dm.mine, let r = report {
                    Text(r.details).font(.caption2).foregroundStyle(r.status == "failed" ? .red : .secondary)
                }
            }
            if let atts = dm.attachments, !atts.isEmpty {
                ForEach(atts, id: \.name) { a in Label("\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))", systemImage: "paperclip").font(.caption) }
            }
        }
        .frame(maxWidth: .infinity, alignment: dm.mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

struct NewConversation: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openConversation) private var navigate
    @State private var to = ""
    @State private var error: String?

    var body: some View {
        let people = model.profiles.filter { $0.key != model.me && ($0.value.name != nil || $0.value.nip05 != nil) }
            .map { (pubkey: $0.key, name: $0.value.name ?? "", nip05: $0.value.nip05) }
            .sorted { $0.name < $1.name }
        let q = to.lowercased()
        let matches = q.isEmpty ? Array(people.prefix(8)) : people.filter { $0.name.lowercased().contains(q) || ($0.nip05?.lowercased().contains(q) ?? false) }
        NavigationStack {
            List {
                Section {
                    TextField("A name, name@\(model.config.domain) or an e-mail address", text: $to)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.emailAddress)
                        .onSubmit(go)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Members") {
                    ForEach(matches, id: \.pubkey) { p in
                        Button { open("n:" + p.pubkey) } label: {
                            HStack { Avatar(pubkey: p.pubkey, size: 30); VStack(alignment: .leading) { Text(p.name); if let n = p.nip05 { Text(n).font(.caption).foregroundStyle(.secondary) } } }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Next", action: go).disabled(to.isEmpty) }
            }
        }
    }

    func go() {
        let people = model.profiles.map { (pubkey: $0.key, name: $0.value.name ?? "", nip05: $0.value.nip05) }
        Task {
            if let c = await model.dms?.conv(for: to, people: people) { open(c) } else { error = "That's not a member nor an e-mail address." }
        }
    }

    func open(_ conv: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { navigate(conv) }
    }
}
