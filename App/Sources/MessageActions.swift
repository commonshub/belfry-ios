import BelfryCore
import SwiftUI

// The message menu (a Discord-style list: quick reactions, then grouped rows with line icons),
// the in-app delete confirmation showing the message (SPEC 19.2), the edit sheet (19.1) and
// the shared inbox's "Reply by e-mail" with its 8 s Undo.

struct MessageActions: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let m: Message
    let group: String
    let onReply: () -> Void
    let onOpenThread: () -> Void
    let onEdit: () -> Void
    @State private var confirmDelete = false
    @State private var moreEmoji = false
    @State private var copied = false

    var body: some View {
        let d = model.derive
        let pending = model.pending(m.id) != nil
        let isReply = m.ev.kind == 1111
        VStack(spacing: 0) {
            if confirmDelete {
                DeleteConfirm(m: m, group: group, cancel: { withAnimation { confirmDelete = false } }) { dismiss() }
            } else {
                List {
                    if !pending && !isReply {
                        Section {
                            HStack(spacing: 0) {
                                ForEach(EmojiUsage.top(6), id: \.self) { e in
                                    Button {
                                        model.toggleReaction(e, on: m, in: group)
                                        dismiss()
                                    } label: { Text(e).font(.title2).frame(maxWidth: .infinity, minHeight: 44) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("React with \(e)")
                                }
                                Button { moreEmoji = true } label: {
                                    Image(systemName: "face.smiling").font(.title3).frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("More reactions")
                            }
                        }
                    }
                    Section {
                        if !pending {
                            Button { dismiss(); onReply() } label: { ActionRow(icon: "arrowshape.turn.up.left", title: "Reply") }
                            if !isReply {
                                Button { dismiss(); onOpenThread() } label: { ActionRow(icon: "bubble.left.and.bubble.right", title: "Open thread") }
                            }
                        }
                        if d.canEdit(m) {
                            Button { dismiss(); onEdit() } label: { ActionRow(icon: "pencil", title: "Edit message") }
                        }
                        if !m.text.isEmpty {
                            Button {
                                UIPasteboard.general.string = d.plainRefs(m.text, npub: "@…")
                                copied = true
                                dismiss()
                            } label: { ActionRow(icon: "doc.on.doc", title: "Copy text") }
                        }
                        Button {
                            UIPasteboard.general.string = d.channelURL(group)
                            dismiss()
                        } label: { ActionRow(icon: "link", title: "Copy link to the channel") }
                        if m.pubkey != model.me && !d.isGuest(model.me) {
                            Button {
                                dismiss()
                                model.messageAuthor = m.pubkey
                            } label: { ActionRow(icon: "envelope", title: "Message \(model.realNameOrKey(m.pubkey))") }
                        }
                    }
                    if !pending {
                        Section {
                            if !isReply && d.canPin(group) {
                                let on = d.isPinned(group, m.id)
                                ActionButtonRow(icon: on ? "pin.slash" : "pin", title: on ? "Unpin from the channel" : "Pin to the channel") {
                                    model.pin(m, in: group, !on)
                                    dismiss()
                                }
                            }
                            if !isReply && d.canMakeTodo(group, m) {
                                ActionButtonRow(icon: "checklist", title: "Turn into a to-do", detail: d.todoTitle(m)) {
                                    model.makeTodo(m, in: group)
                                    dismiss()
                                }
                            }
                            if let ref = nsiteRef(m.text), d.isCommunityAdmin {
                                ActionButtonRow(icon: "globe", title: "Make this the website") {
                                    model.website = await model.publishWebsite(ref: ref, message: m.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                    if d.canDelete(m) || pending && m.pubkey == model.me {
                        Section {
                            Button { withAnimation { confirmDelete = true } } label: {
                                ActionRow(icon: "trash", title: pending ? "Discard" : "Delete message", destructive: true)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .presentationDetents(confirmDelete ? Set([PresentationDetent.medium]) : Set([PresentationDetent.medium, .large]))
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $moreEmoji) {
            EmojiPicker { e in
                model.toggleReaction(e, on: m, in: group)
                moreEmoji = false
                dismiss()
            }
        }
        .onAppear {
            if model.launchDelete { model.launchDelete = false; confirmDelete = true }
        }
    }

    /// An nsite link in a message: nsite:<npub>[/<name>] (SPEC: "Make this the website").
    func nsiteRef(_ text: String) -> String? {
        Rx("nsite:(npub1[02-9ac-hj-np-z]{58}(?:/[a-z0-9-]{1,40})?)").first(text)?[1]
    }
}

/// "Delete this message?" inside the menu, showing the message (SPEC 19.2).
struct DeleteConfirm: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        let pending = model.pending(m.id)
        VStack(alignment: .leading, spacing: 14) {
            Text(pending == nil ? "Delete this message?" : "Discard this message?").font(.title3.bold())
            HStack(alignment: .top, spacing: 10) {
                Avatar(pubkey: m.pubkey, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.derive.nameOver(m)).font(.subheadline.weight(.semibold))
                    Text(model.derive.deletePreview(m)).font(.subheadline).foregroundStyle(.secondary).lineLimit(6)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            Text(pending == nil ? "It disappears for everyone, with its reactions. This can't be undone." : "It was never sent: it disappears from this phone.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.bordered).frame(maxWidth: .infinity)
                BusyButton(role: .destructive) {
                    model.delete(m, in: group)
                    done()
                } label: { Text(pending == nil ? "Delete" : "Discard").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(20)
    }
}

struct EmojiPicker: View {
    let pick: (String) -> Void
    static let all = ["👍", "❤️", "😂", "🎉", "🙏", "👀", "🔥", "👏", "😍", "🤔", "😮", "😢",
                      "😅", "🙌", "💪", "✅", "❌", "💯", "🚀", "✨", "🌱", "☕", "🍕", "🍻",
                      "😊", "😎", "🤗", "🥳", "😴", "🤯", "😬", "🙈", "👋", "🤝", "👌", "✌️",
                      "💡", "📌", "📅", "⏰", "🎶", "📷", "🌞", "🌧️", "❄️", "🌈", "🐝", "🌻"]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(EmojiPicker.all, id: \.self) { e in
                    Button { pick(e) } label: { Text(e).font(.largeTitle) }.buttonStyle(.plain)
                }
            }
            .padding()
        }
        .presentationDetents([.medium])
    }
}

/// Edit my message: the text as I wrote it, channel references back as "#name".
struct EditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let m: Message
    let group: String
    @State private var text = ""
    @State private var picked = [(label: String, ref: String)]()
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(3...12)
                    .font(.body)
                    .focused($focused)
            }
            .navigationTitle("Edit message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    BusyButton("Save") {
                        let sent = ChannelRefs.substitute(text.jsTrim(), picked: picked)
                        model.edit(m, in: group, text: sent)
                        dismiss()
                    }
                    .disabled(text.jsTrim().isEmpty || text.jsTrim() == initial)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let back = model.derive.unsubstituteChannels(m.text)
                text = back.text
                picked = back.picked
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    var initial: String { model.derive.unsubstituteChannels(m.text).text }
}

/// Reply to an inbox card by e-mail as the channel; Send waits 8 s with Undo (nothing leaves before).
struct MailReplySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let card: Message
    let group: String
    let to: String
    let subject: String
    @State private var text = ""
    @State private var countdown: Int?
    @State private var error: String?
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: to)
                    LabeledContent("From", value: "\(group)@\(model.config.domain)")
                    LabeledContent("Subject", value: subject.lowercased().hasPrefix("re:") ? subject : "Re: " + subject)
                }
                Section {
                    TextField("Your answer", text: $text, axis: .vertical).lineLimit(6...16).font(.body)
                        .disabled(countdown != nil)
                }
                if let countdown {
                    Section {
                        HStack {
                            Label("Sending in \(countdown) s", systemImage: "paperplane")
                            Spacer()
                            Button("Undo") { undo() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
            }
            .navigationTitle("Reply by e-mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { undo(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { start() }.disabled(text.jsTrim().isEmpty || countdown != nil)
                }
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    func start() {
        error = nil
        countdown = 8
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                guard let c = countdown else { t.invalidate(); return }
                if c <= 1 {
                    t.invalidate()
                    countdown = nil
                    if let e = await model.replyAsChannel(card, in: group, to: to, subject: subject, text: text.jsTrim()) {
                        error = e
                    } else {
                        dismiss()
                    }
                } else {
                    countdown = c - 1
                }
            }
        }
    }

    func undo() {
        timer?.invalidate()
        timer = nil
        countdown = nil
    }
}
