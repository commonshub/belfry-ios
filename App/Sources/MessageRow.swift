import BelfryCore
import SwiftUI

// One message in the feed, and what hangs off it: cards (pod, proposal, event, e-mail), the
// "edited" mark, topic chips, the to-do mark, reactions, the thread chip + "Open thread", outbox
// states; the inline thread, resurfaced threads and join lines.

struct MessageRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let m: Message
    let group: String
    let first: Bool
    let reactions: [Reaction]
    let thread: ThreadInfo?
    let threadOpen: Bool
    let announce: Bool
    var todo: TodoTask?
    var pinned = false
    var openTopic: String?
    var flash = false
    let onThread: () -> Void
    let onOpenThread: () -> Void
    let onReply: () -> Void
    let onHold: () -> Void
    var onTopic: (String) -> Void = { _ in }
    @State private var tapped = 0

    var body: some View {
        let d = model.derive
        let pending = model.pending(m.id)
        HStack(alignment: .top, spacing: 10) {
            if first {
                Avatar(pubkey: m.ev.pubkey, size: 36).onTapGesture { model.openProfile = m.ev.pubkey }
            } else { Color.clear.frame(width: 36, height: 1) }
            VStack(alignment: .leading, spacing: 4) {
                if first {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(d.nameOver(m)).font(.subheadline.weight(.semibold)).lineLimit(1).onTapGesture { model.openProfile = m.ev.pubkey }
                        Text(Format.time(m.ev.createdAt)).font(.caption).foregroundStyle(.secondary)
                        if announce { Label("Announcement", systemImage: "megaphone").font(.caption2.weight(.semibold)).foregroundStyle(Color.bronze) }
                        if pinned { Image(systemName: "pin").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
                    }
                }
                if let created = m.created {
                    Text("Created \(created)").font(.caption).foregroundStyle(.secondary)
                }
                SpecialBody(m: m, group: group)
                if !m.eventRefs.isEmpty {
                    ForEach(m.eventRefs, id: \.self) { r in EventCardView(ref: r) }
                }
                ForEach(m.media, id: \.url) { media in MediaView(media: media) }
                if let e = m.edited { Text("edited").font(.caption2).foregroundStyle(.secondary).accessibilityLabel("Edited \(Format.ago(e))") }
                let extra = d.extraTopics(m, openTopic: openTopic)
                if !extra.isEmpty {
                    FlowRow(spacing: 4) {
                        ForEach(extra, id: \.self) { t in
                            Button { onTopic(t) } label: { Chip(text: "#" + t, tint: .bronze) }.buttonStyle(.plain)
                        }
                    }
                }
                if let todo {
                    BusyButton {
                        model.todo(todo, in: group, todo.done ? "undone" : "done")
                    } label: {
                        Chip(text: d.todoChip(todo), icon: todo.done ? "checkmark.square" : "square", tint: todo.done ? .green : .bronze)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(todo.done ? "Marks it as not done" : "Ticks it off")
                }
                if !reactions.isEmpty {
                    ReactionBar(reactions: reactions) { emoji in model.toggleReaction(emoji, on: m, in: group); tapped += 1 }
                }
                if let thread, thread.count > 0 {
                    HStack(spacing: 12) {
                        Button(action: onThread) {
                            HStack(spacing: 6) {
                                HStack(spacing: -6) { ForEach(thread.who.prefix(3), id: \.self) { Avatar(pubkey: $0, size: 18) } }
                                Text(threadOpen ? "Hide replies" : "\(thread.count) \(thread.count == 1 ? "reply" : "replies")").font(.caption.weight(.semibold))
                                Text(Format.short(thread.last)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(threadOpen ? "Hide replies" : "\(thread.count) replies")
                        Button(action: onOpenThread) {
                            HStack(spacing: 2) { Text("Open thread"); Image(systemName: "chevron.right") }.font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(Color.bronze)
                }
                if let p = pending {
                    if p.status == .failed {
                        HStack(spacing: 10) {
                            Label("Not sent", systemImage: "exclamationmark.circle").foregroundStyle(.red)
                            BusyButton("Retry") { model.retry(p.localId) }.font(.caption.weight(.semibold))
                            BusyButton("Discard", role: .destructive) { model.discard(p.localId) }.font(.caption.weight(.semibold))
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
        .padding(.bottom, 2)
        .opacity(pending == nil ? 1 : 0.65)
        .background(flash ? Color.bronze.opacity(0.15) : announce ? Color.bronze.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: tapped)
        .onLongPressGesture(minimumDuration: 0.35) { onHold() }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Actions") { onHold() }
        .accessibilityHint("Touch and hold for actions")
    }
}

/// What the text part of a message shows: plain text, or an e-mail / inbox / sent-as card.
struct SpecialBody: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openChannel) private var openChannel
    let m: Message
    let group: String

    var body: some View {
        switch m.special {
        case .podCard(let pid):
            let g = model.group(pid)
            Button { openChannel(pid, nil) } label: {
                CardFrame {
                    HStack(spacing: 10) {
                        if let g { ChannelGlyph(group: g, size: 26) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g?.name ?? "A pod").font(.subheadline.weight(.semibold))
                            Text(g.map { "\($0.members.count) \($0.members.count == 1 ? "member" : "members") · \($0.closed ? "by application" : "open to join")" } ?? "Pod")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }.buttonStyle(.plain)
        case .proposalCard(let pid):
            let p = model.derive.proposalFor(pid)
            Button { openChannel(pid, nil) } label: {
                CardFrame {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Image(systemName: "doc.text"); Text(p?.title ?? model.group(pid)?.name ?? "A proposal").font(.subheadline.weight(.semibold)) }
                        if let p, !p.summary.isEmpty { Text(p.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if let p {
                            HStack(spacing: 6) {
                                Chip(text: p.status.label, tint: p.votingNow ? .bronze : .secondary)
                                Text("version \(p.version)").font(.caption2).foregroundStyle(.secondary)
                                if p.votingNow { Text("\(p.tally["yes"] ?? 0) yes · \(p.tally["no"] ?? 0) no").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }.buttonStyle(.plain)
        case .eventCard(let coord):
            EventCardView(ref: EventRef(coord: coord))
        case .memberMail(let subject, _):
            VStack(alignment: .leading, spacing: 4) {
                Label("via e-mail", systemImage: "envelope").font(.caption2).foregroundStyle(.secondary)
                if !subject.isEmpty { Text(subject).font(.subheadline.weight(.semibold)) }
                if !m.body.isEmpty { MarkdownText(text: m.body) }
            }
        case .inboxCard(let from, let name, let subject, _, let verified, _):
            InboxCardView(m: m, group: group, from: from, name: name, subject: subject, verified: verified)
        case .sentAsChannel(let to, let subject, let by):
            CardFrame {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Sent by e-mail as the channel to \(to)", systemImage: "paperplane").font(.caption).foregroundStyle(.secondary)
                    if !subject.isEmpty { Text(subject).font(.subheadline.weight(.semibold)) }
                    if !m.text.isEmpty { MarkdownText(text: m.text) }
                    if !by.isEmpty { Text("Written by \(model.name(by))").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        case .none:
            if !m.text.isEmpty { MarkdownText(text: m.text) }
        }
    }
}

/// A shared inbox card: the sender, verified or not, the subject and its state (SPEC 19.6).
struct InboxCardView: View {
    @EnvironmentObject var model: AppModel
    let m: Message
    let group: String
    let from: String
    let name: String
    let subject: String
    let verified: Bool
    @State private var reply = false

    var body: some View {
        let st = model.derive.inboxStates(group)[m.id] ?? CardState()
        let admin = model.derive.canAdmin(group)
        CardFrame(tint: .bronze) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "envelope.fill").foregroundStyle(Color.bronze)
                    Text(name.isEmpty ? from : "\(name) <\(from)>").font(.caption.weight(.semibold)).lineLimit(1)
                    if verified { Image(systemName: "checkmark.seal").font(.caption).foregroundStyle(.green).accessibilityLabel("Verified sender") }
                }
                if !subject.isEmpty { Text(subject).font(.subheadline.weight(.semibold)) }
                if !m.body.isEmpty { MarkdownText(text: m.body).lineLimit(8) }
                HStack(spacing: 8) {
                    Chip(text: st.status.label, tint: st.status == .open ? .bronze : .secondary)
                    if let a = st.assignee { Text(a == model.me ? "You have it" : "\(model.name(a)) has it").font(.caption2).foregroundStyle(.secondary) }
                }
                if admin {
                    FlowRow(spacing: 8) {
                        Button { reply = true } label: { Label("Reply by e-mail", systemImage: "arrowshape.turn.up.left") }
                        if st.assignee == model.me {
                            BusyButton { model.assignCard(m, in: group, to: "") } label: { Label("Let go", systemImage: "hand.raised.slash") }
                        } else {
                            BusyButton { model.assignCard(m, in: group, to: model.me) } label: { Label("Take it", systemImage: "hand.raised") }
                        }
                        BusyButton { model.setCard(m, in: group, closed: st.status != .closed) } label: {
                            Label(st.status == .closed ? "Reopen" : "Close", systemImage: st.status == .closed ? "arrow.uturn.backward" : "checkmark")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .sheet(isPresented: $reply) { MailReplySheet(card: m, group: group, to: from, subject: subject) }
    }
}

struct CardFrame<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder let content: () -> Content
    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: 420, alignment: .leading)
            .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25)))
    }
}

/// An event's card (Belfry event or older session): date chip, title, place, my state.
struct EventCardView: View {
    @EnvironmentObject var model: AppModel
    let ref: EventRef

    var body: some View {
        let d = model.derive
        let e = ref.coord.flatMap { d.calEvent($0) } ?? ref.link.flatMap { d.eventByLink($0) }
        Button { model.openEvent = e?.coord ?? ref.link } label: {
            CardFrame {
                if let e {
                    HStack(alignment: .top, spacing: 10) {
                        DateChip(at: e.start)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(e.allDay ? "All day" : d.lineWhen(e)).font(.caption).foregroundStyle(.secondary)
                            if let l = e.location, !l.isEmpty { Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            HStack(spacing: 6) {
                                if e.status == .cancelled { Chip(text: "Cancelled", tint: .red) }
                                if let s = d.stateLabel(e) { Chip(text: s, tint: .bronze) }
                                if e.going > 0 { Text("\(e.going) going").font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    Label("An event", systemImage: "calendar").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct DateChip: View {
    let at: Int
    var body: some View {
        let date = Date(timeIntervalSince1970: TimeInterval(at))
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.caption2.weight(.bold)).foregroundStyle(Color.bronze)
            Text(date.formatted(.dateTime.day())).font(.title3.weight(.semibold))
        }
        .frame(width: 44, height: 44)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityHidden(true)
    }
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

struct MediaView: View {
    let media: Media
    var body: some View {
        if media.mime.hasPrefix("image/"), let url = URL(string: media.url), url.scheme == "https" || url.scheme == "http" {
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
        } else if media.mime.hasPrefix("image/") {
            Label(media.name ?? "Photo", systemImage: "photo").foregroundStyle(.secondary)
        } else if let url = URL(string: media.url), url.scheme == "https" {
            Link(destination: url) { Label(media.name ?? "File", systemImage: "paperclip") }.font(.callout)
        }
    }
}

/// The latest three replies under a message, "Show N earlier", a reply box and "Open thread".
struct InlineThread: View {
    @EnvironmentObject var model: AppModel
    let group: String
    let root: Message
    let onOpen: () -> Void
    let onHold: (Message) -> Void
    let onHide: () -> Void
    @State private var all = false

    var body: some View {
        let (shown, hidden) = model.derive.inlineThread(group, root.id, showAll: all)
        VStack(alignment: .leading, spacing: 8) {
            if hidden > 0 {
                Button("Show \(hidden) earlier \(hidden == 1 ? "reply" : "replies")") { withAnimation { all = true } }
                    .font(.caption.weight(.semibold))
            }
            ForEach(shown) { r in ReplyRow(r: r, onHold: { onHold(r) }) }
            if !model.guestReading {
                Composer(group: group, placeholder: shown.isEmpty ? "Reply (starts a thread)" : "Reply in the thread", compact: true) { text, _, _ in
                    model.reply(text, in: group, to: root)
                }
            }
            HStack(spacing: 16) {
                Button("Hide", action: onHide)
                Button(action: onOpen) { HStack(spacing: 2) { Text("Open thread"); Image(systemName: "chevron.right") } }
            }
            .font(.caption.weight(.semibold))
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

struct ReplyRow: View {
    @EnvironmentObject var model: AppModel
    let r: Message
    let onHold: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Avatar(pubkey: r.ev.pubkey, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name(r.ev.pubkey)).font(.caption.weight(.semibold))
                    Text(Format.time(r.ev.createdAt)).font(.caption2).foregroundStyle(.secondary)
                    if r.edited != nil { Text("edited").font(.caption2).foregroundStyle(.secondary) }
                    if let p = model.pending(r.id) { Text(p.stateText).font(.caption2).foregroundStyle(p.status == .failed ? .red : .secondary) }
                }
                if !r.text.isEmpty { MarkdownText(text: r.text).font(.subheadline) }
                ForEach(r.media, id: \.url) { MediaView(media: $0) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.35) { onHold() }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Actions") { onHold() }
    }
}

struct ThreadActivity: View {
    @EnvironmentObject var model: AppModel
    let root: Message
    let last: Message
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        let d = model.derive
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.name(last.ev.pubkey)) replied to \(model.name(root.ev.pubkey)): “\(d.activitySnippet(root))”")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text(d.activityReply(last)).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
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
}

/// "<name> joined as a guest, invited by <name>" (SPEC 13, 19.3, 19.16).
struct JoinLine: View {
    @EnvironmentObject var model: AppModel
    let join: GuestJoin
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.right").foregroundStyle(Color.bronze)
            Text(LocalizedStringKey(text)).font(.footnote)
            Spacer(minLength: 0)
            Text(Format.time(join.at)).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    var text: String {
        let who = "**\(model.name(join.pubkey))**"
        if let owner = model.derive.agentOwner(join.pubkey) {
            return owner == model.me ? "\(who) joined as your agent" : "\(who) joined as **\(model.realNameOrKey(owner))**'s agent"
        }
        let what = join.agent ? "an agent" : "a guest"
        guard let by = join.by else { return "\(who) joined as \(what)" }
        return "\(who) joined as \(what), invited by **\(model.name(by))**" + (join.unsaved && !join.agent ? " · not saved" : "")
    }
}
