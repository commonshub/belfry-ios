import BelfryCore
import SwiftUI

// "Sign in with <domain>": the community's address, then the belfry's own sign-in page in the
// system browser session (e-mail + 6-digit code). The member's key stays on the belfry.

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    var domainHint: String?
    @AppStorage("last-domain") private var domain = ""
    @State private var auth = WebAuth()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    BelfryMark()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your community's chat")
                            .font(.largeTitle.bold())
                        Text("Channels, threads and messages that live on your community's own server, its belfry.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Community address").font(.subheadline.weight(.semibold))
                        TextField("belfry.sh", text: $domain)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .focused($focused)
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            .onSubmit(go)
                            .accessibilityLabel("Community address")
                    }
                    if let e = model.signInError {
                        Label(e, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                    Button(action: go) {
                        HStack {
                            if model.busy { ProgressView().tint(.white) }
                            Text(domain.isEmpty ? "Sign in" : "Sign in with \(domain.lowercased())")
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || domain.trimmingCharacters(in: .whitespaces).isEmpty)
                    Text("You'll type your e-mail address and the 6-digit code the belfry sends you. Your key stays on the belfry; this phone only gets a session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Divider()
                    Button("Try the demo") { model.startDemo() }
                        .font(.callout)
                }
                .padding(24)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if let h = domainHint { domain = h } }
        }
    }

    private func go() {
        focused = false
        Task { await model.signIn(domain: domain, auth: auth) }
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
