import BelfryCore
import SwiftUI

// Signing in (SPEC 19.20): the member's address name@domain, then the 6-digit code the belfry
// mails, typed here. No browser. The belfry's own sign-in page in the system browser session
// (SPEC 2) stays as a second row, and is what an older belfry gets. The member's key stays on
// the belfry; this phone holds a session key.

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    /// A guest link's domain: the placeholder names it.
    var domainHint: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                SwiftUI.Group {
                    if let pending = model.pendingCode {
                        CodeScreen(pending: pending)
                    } else {
                        AddressScreen(domainHint: domainHint)
                    }
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Screen 1: one field, the address.
private struct AddressScreen: View {
    @EnvironmentObject var model: AppModel
    var domainHint: String?
    @AppStorage("last-address") private var address = ""
    @State private var auth = WebAuth()
    @State private var error: String?
    /// An older belfry (no session API): the main button opens the browser sign-in.
    @State private var offerBrowser = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BelfryMark()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your community's chat")
                    .font(.largeTitle.bold())
                Text("Type your address in your community. A 6-digit code goes to your e-mail; no password.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Your address").font(.subheadline.weight(.semibold))
                TextField("name@" + (domainHint ?? "belfry.sh"), text: $address)
                    .font(.body)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.continue)
                    .focused($focused)
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(go)
                    .disabled(model.busy)
                    .accessibilityLabel("Your address")
                    .onChange(of: address) { _, _ in
                        if model.launch.signin == nil { offerBrowser = false }
                    }
            }
            if let note = model.signInNote {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if let e = error ?? model.signInError {
                Label(e, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
            // locks on the tap (model.busy) and shows progress until the belfry answered
            Button(action: go) {
                HStack {
                    if model.busy { ProgressView().tint(.white) }
                    Text(offerBrowser ? "Sign in with the browser" : "Continue")
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || address.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Your key stays on the belfry; this phone only gets a session.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                if !offerBrowser {
                    ActionButtonRow(icon: "globe", title: "Sign in with the browser instead", detail: "On your community's own sign-in page") {
                        await browser()
                    }
                    .disabled(model.busy)
                }
                Button { model.startDemo() } label: {
                    ActionRow(icon: "person.2", title: "Try the demo", detail: "A made-up community. Everything in it stays on this device.")
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
        }
        .onAppear {
            if model.launch.signin == "older" {
                address = "maya@riverside.example"
                offerBrowser = true
                error = SessionFailure.unsupported.message
            }
        }
    }

    private func go() {
        guard !model.busy else { return }
        focused = false
        error = nil
        model.signInError = nil
        if model.launch.signin != nil { return }
        model.busy = true
        Task { @MainActor in
            if offerBrowser {
                await browser()
            } else if let e = await model.requestCode(address) {
                if e.failure == .unsupported { offerBrowser = true }
                error = e.display
            }
            model.busy = false
        }
    }

    /// The belfry's own page (SPEC 2), at the domain of the address typed (or a bare domain).
    private func browser() async {
        error = nil
        model.signInError = nil
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let domain = MemberAddress.parse(typed)?.domain ?? (Discovery.isDomain(typed) ? typed : nil) else {
            error = "Type your address first, like name@belfry.sh."
            return
        }
        focused = false
        await model.signIn(domain: domain, auth: auth)
    }
}

/// Screen 2: the six digits of the code.
private struct CodeScreen: View {
    @EnvironmentObject var model: AppModel
    let pending: PendingCode
    @State private var digits = ""
    @State private var verifying = false
    @State private var error: String?
    @State private var note: String?
    /// The digits are right as far as we know (no connection, too many tries): the same code again.
    @State private var canRetry = false
    /// "Send a new code" is locked for 30 s after each send.
    @State private var resendAt = Date().addingTimeInterval(30)
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BelfryMark()
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Enter the code").font(.largeTitle.bold())
                // the address is what the person typed (checked); `to` passed the mask check
                Text("We sent a 6-digit code to \(pending.to ?? "your e-mail address") to sign in as \(pending.address). It works for 10 minutes.")
                    .foregroundStyle(.secondary)
            }
            CodeBoxes(digits: $digits, enabled: !verifying, focused: $focused) { Task { await submit() } }
            if verifying {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Signing you in…")
                }
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            } else if let note {
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if canRetry && !verifying {
                BusyButton { await submit() } label: { Text("Try again").frame(maxWidth: .infinity).padding(.vertical, 6) }
                    .buttonStyle(.borderedProminent)
            }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = max(0, Int(resendAt.timeIntervalSince(context.date).rounded(.up)))
                    ActionButtonRow(icon: "envelope", title: wait > 0 ? "Send a new code (in \(wait) s)" : "Send a new code") {
                        await resend()
                    }
                    .disabled(wait > 0 || verifying)
                    .opacity(wait > 0 ? 0.5 : 1)
                }
                Button { model.cancelCode() } label: { ActionRow(icon: "chevron.left", title: "Use another address") }
                    .buttonStyle(.plain)
                    .disabled(verifying)
            }
        }
        .onAppear {
            if model.launch.signin == "code" { digits = "427" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { focused = true }
        }
    }

    private func submit() async {
        guard !verifying, NativeSignIn.isCode(digits) else { return }
        if model.launch.signin != nil { return }
        verifying = true
        error = nil
        note = nil
        focused = false
        let e = await model.verifyCode(digits)
        verifying = false
        guard let e else { return }
        if e.failure.endsTheRequest { return } // the model went back to screen 1 with its message
        error = e.display
        switch e.failure {
        case .wrongCode:
            digits = ""
            canRetry = false
            focused = true
        case .signer:
            // the code is spent and the belfry's signer was down: a new code, at once
            digits = ""
            canRetry = false
            resendAt = Date()
        default:
            canRetry = true
        }
    }

    private func resend() async {
        if model.launch.signin != nil { return }
        error = nil
        note = nil
        if let e = await model.resendCode() {
            if !e.failure.endsTheRequest { error = e.display }
            return
        }
        digits = ""
        canRetry = false
        note = "A new code is on its way."
        resendAt = Date().addingTimeInterval(30)
        focused = true
    }
}

/// Six boxes over one numeric field: the field takes the typing, a paste ("123 456") and the
/// system's code suggestion; the boxes show it. The sixth digit calls COMPLETE.
struct CodeBoxes: View {
    @Binding var digits: String
    let enabled: Bool
    var focused: FocusState<Bool>.Binding
    let complete: () -> Void

    var body: some View {
        let typed = Array(digits)
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    Text(i < typed.count ? String(typed[i]) : " ")
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(enabled ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(focused.wrappedValue && enabled && i == min(typed.count, 5) ? Color.bronze : Color.clear, lineWidth: 2)
                        )
                }
            }
            .accessibilityHidden(true)
            TextField("", text: $digits)
                .font(.body)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 54)
                .focused(focused)
                .disabled(!enabled)
                .accessibilityLabel("6-digit code")
                .onChange(of: digits) { _, new in
                    let d = NativeSignIn.digits(new)
                    if d != new { digits = d; return } // comes back here with the digits alone
                    if d.count == 6 { complete() }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { if enabled { focused.wrappedValue = true } }
    }
}

/// The Arms mark: a shield with a tower over water.
struct BelfryMark: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var shield = Path()
            shield.move(to: CGPoint(x: w * 0.1, y: h * 0.08))
            shield.addLine(to: CGPoint(x: w * 0.9, y: h * 0.08))
            shield.addLine(to: CGPoint(x: w * 0.9, y: h * 0.5))
            shield.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.95), control: CGPoint(x: w * 0.9, y: h * 0.82))
            shield.addQuadCurve(to: CGPoint(x: w * 0.1, y: h * 0.5), control: CGPoint(x: w * 0.1, y: h * 0.82))
            shield.closeSubpath()
            ctx.fill(shield, with: .color(.bronze))
            var tower = Path()
            tower.addRect(CGRect(x: w * 0.4, y: h * 0.3, width: w * 0.2, height: h * 0.32))
            tower.move(to: CGPoint(x: w * 0.36, y: h * 0.3))
            tower.addLine(to: CGPoint(x: w * 0.5, y: h * 0.17))
            tower.addLine(to: CGPoint(x: w * 0.64, y: h * 0.3))
            tower.closeSubpath()
            ctx.fill(tower, with: .color(.white))
            for i in 0..<2 {
                var wave = Path()
                let y = h * (0.7 + Double(i) * 0.08)
                wave.move(to: CGPoint(x: w * 0.24, y: y))
                wave.addCurve(to: CGPoint(x: w * 0.76, y: y), control1: CGPoint(x: w * 0.4, y: y - h * 0.05), control2: CGPoint(x: w * 0.6, y: y + h * 0.05))
                ctx.stroke(wave, with: .color(.white), lineWidth: max(1.5, w * 0.035))
            }
        }
    }
}
