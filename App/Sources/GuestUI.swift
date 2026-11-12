import BelfryCore
import SwiftUI

// Guest mode's own screens (SPEC 19.26; web GuestJoin.tsx): the one loading screen from a guest
// link to its channel, the screen of a link that can't be used, the bar standing where the
// composer would be, and the Join sheet (name and e-mail, then the code sent by e-mail). Every
// text is fixed or comes from the belfry's answer; nothing from the link's address.

/// From the link to the channel: one calm screen, nothing else drawn in between.
struct OpeningScreen: View {
    let opening: Opening

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            SwiftUI.Group {
                if let name = opening.name, !name.isEmpty { Text("Opening ") + Text("# \(name)").bold() + Text("…") } else { Text("Opening…") }
            }
            .font(.title3)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// A guest link that can't be used (closed, unknown, no connection): why, and what to do.
struct InviteProblemScreen: View {
    @EnvironmentObject var model: AppModel
    let problem: InviteProblem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                BelfryMark().frame(width: 56, height: 56).accessibilityHidden(true)
                Text("This invite can’t be used").font(.title.bold())
                Label(problem.message, systemImage: problem.closed ? "xmark.octagon" : "exclamationmark.triangle")
                    .foregroundStyle(problem.closed ? .red : .primary)
                if !problem.closed {
                    Button { model.retryInvite() } label: { Text("Try again").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent)
                }
                Button {
                    if problem.closed { model.pendingInvite = nil }
                    model.inviteSignInFirst = true
                } label: { Text("I have an account: sign in").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered)
                Button("Close") { model.dropInvite() }.frame(maxWidth: .infinity)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Where the composer would be: you are reading; Join opens the sheet.
struct GuestBar: View {
    @EnvironmentObject var model: AppModel
    let group: String

    var body: some View {
        let g = model.group(group)
        HStack(spacing: 12) {
            (Text("Guest mode").bold() + Text(" · You’re reading \(g.map { $0.isPod ? $0.name : "#" + $0.name } ?? "#" + group) as a guest."))
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Join") { model.joinAsked = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Guest mode")
    }
}

/// Join (guest mode: name + e-mail) or save the account (a guest with a name: the e-mail only),
/// then the code step, which says where the code went. 409 `taken`: "Sign in instead".
struct JoinSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// A guest who has a name already: the e-mail alone.
    var saveOnly = false
    var onSaved: ((String) -> Void)?

    enum Step { case who, code, taken }
    @State private var step = Step.who
    @State private var name = ""
    @State private var email = ""
    @State private var digits = ""
    @State private var verifying = false
    @State private var error: String?
    @State private var note: String?
    @State private var moved = false
    /// What the person typed, as it was when the code went out.
    @State private var sentTo = ""
    @State private var resendAt = Date()
    @State private var launched = false
    @FocusState private var codeFocused: Bool

    var askName: Bool { !saveOnly }

    var label: String {
        let id = model.guestChannel ?? ""
        let g = model.group(id)
        return g.map { $0.isPod ? $0.name : "# " + $0.name } ?? (id.isEmpty ? "" : "# " + id)
    }

    var title: String {
        switch step {
        case .code: return "Check your e-mail"
        case .taken: return "You have an account here"
        case .who: return saveOnly ? "Save your account" : (label.isEmpty ? "Join" : "Join \(label)")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch step {
                    case .who: who
                    case .code: code
                    case .taken: taken
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() }.disabled(verifying) } }
        }
        .interactiveDismissDisabled(verifying)
        .onAppear {
            // screenshots: the code step with a made-up address (nothing is sent)
            if model.launch.guest == "code", !launched { launched = true; name = "Lou"; sentTo = "lou@example.org"; step = .code; resendAt = Date().addingTimeInterval(30) }
        }
    }

    @ViewBuilder var who: some View {
        Text(saveOnly
             ? "Add your e-mail address to come back from any device. We’ll send a 6-digit code to it."
             : "Your name and e-mail address, and you can write here. We’ll send a 6-digit code to your e-mail to confirm it.")
            .foregroundStyle(.secondary)
        if askName {
            field("Your name") {
                TextField("The name people here will see", text: $name)
                    .textContentType(.name)
                    .submitLabel(.next)
            }
        }
        field("E-mail") {
            TextField("you@example.org", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
        BusyButton { _ = await send() } label: { Text("Continue").frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent)
            .disabled(!GuestJoinForm.canContinue(name: name, email: email, askName: askName))
        if !saveOnly {
            Text("Already have an account on \(model.config.domain)? Use its e-mail address.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    func field<F: View>(_ label: String, @ViewBuilder _ f: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            f()
                .font(.body)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder var code: some View {
        (Text("We sent a 6-digit code ") + Text("by e-mail").bold() + Text(" to ") + Text(sentTo).bold() + Text(". It can take a minute."))
        CodeBoxes(digits: $digits, enabled: !verifying, focused: $codeFocused) { Task { await verify() } }
        SwiftUI.Group {
            if verifying {
                HStack(spacing: 10) { ProgressView(); Text("Checking the code…") }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let note {
                Text(note).foregroundStyle(.secondary)
            } else {
                Text("Not there? Look in your spam folder.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        Divider()
        VStack(alignment: .leading, spacing: 18) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let wait = max(0, Int(resendAt.timeIntervalSince(context.date).rounded(.up)))
                ActionButtonRow(icon: "envelope", title: wait > 0 ? "Send a new code (in \(wait) s)" : "Send a new code") {
                    if await send() { note = "A new code is on its way to your e-mail." }
                }
                .disabled(wait > 0 || verifying)
                .opacity(wait > 0 ? 0.5 : 1)
            }
            Button {
                step = .who; error = nil; note = nil; digits = ""
            } label: { ActionRow(icon: "chevron.left", title: "Use another address") }
            .buttonStyle(.plain)
            .disabled(verifying)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { codeFocused = true } }
    }

    @ViewBuilder var taken: some View {
        Text(GuestJoinError.taken.message).font(.headline)
        Text(sentTo).bold()
        Text(moved && !label.isEmpty ? "Sign in with it: \(label) is waiting there." : "Sign in with it instead.").foregroundStyle(.secondary)
        BusyButton {
            await model.signInInstead(channel: model.guestChannel ?? "", moved: moved)
        } label: { Text("Sign in instead").frame(maxWidth: .infinity).padding(.vertical, 6) }
        .buttonStyle(.borderedProminent)
        if !moved {
            Button { step = .who; error = nil } label: { Text("Use another address").frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.bordered)
        }
    }

    private func fail(_ f: GuestJoinFailure) {
        if f.error == .taken { moved = f.moved; step = .taken; error = nil; return }
        error = f.error.message
    }

    @discardableResult
    private func send() async -> Bool {
        error = nil
        note = nil
        let typed = email.jsTrim()
        if let f = await model.sendJoinCode(email: typed, name: askName ? name : nil) { fail(f); return false }
        sentTo = typed
        digits = ""
        resendAt = Date().addingTimeInterval(30)
        step = .code
        return true
    }

    private func verify() async {
        guard !verifying, NativeSignIn.isCode(digits) else { return }
        if model.launch.guest == "code" { return } // screenshots send nothing
        verifying = true
        error = nil
        note = nil
        codeFocused = false
        let f = await model.verifyJoinCode(email: sentTo, code: digits, name: askName ? name : nil)
        verifying = false
        if let f {
            digits = ""
            fail(f)
            if step == .code { codeFocused = true }
            return
        }
        onSaved?(sentTo)
        dismiss()
    }
}
