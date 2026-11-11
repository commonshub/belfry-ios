import BelfryCore
import SwiftUI

// Guest links (SPEC 19.4): https://chat.<domain>/join/<token> opens the app (universal link).
// Signed out: the join screen (what the belfry says about the invite, a name, Join) or sign in
// first and join with the account. Signed in: "Join with your account". Only the link's domain
// and token are read; everything shown comes from the belfry's answer or is a fixed text.

struct JoinScreen: View {
    @EnvironmentObject var model: AppModel
    let invite: PendingInvite
    @State private var info: InviteInfo?
    @State private var loadError: String?
    @State private var name = ""
    @State private var error: String?
    @State private var signIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    BelfryMark().frame(width: 56, height: 56).accessibilityHidden(true)
                    if let info {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(info.inviter.isEmpty ? "You're invited" : "\(info.inviter) invites you").font(.title.bold())
                            Text("to \(info.channelName) on \(info.community.isEmpty ? invite.domain : info.community)").font(.title3)
                            if !info.about.isEmpty { Text(info.about).foregroundStyle(.secondary) }
                        }
                        if let closed = info.closedMessage {
                            Label(closed, systemImage: "xmark.octagon").foregroundStyle(.red)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Your name").font(.subheadline.weight(.semibold))
                                TextField("The name people here will see", text: $name)
                                    .font(.body)
                                    .textContentType(.name)
                                    .padding(12)
                                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                            }
                            BusyButton {
                                error = await model.joinAsNew(invite, name: name.jsTrim())
                            } label: { Text("Join").frame(maxWidth: .infinity).padding(.vertical, 6) }
                            .buttonStyle(.borderedProminent)
                            .disabled(name.jsTrim().isEmpty)
                            Text("You'll be a guest of \(info.channelName) for \(info.days) days: you see this channel only. You can save your account with your e-mail later.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if let loadError {
                        Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        BusyButton("Try again") { await load() }.buttonStyle(.bordered)
                    } else {
                        ProgressView("Reading the invite…")
                    }
                    if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).font(.callout) }
                    Divider()
                    Button("I have an account: sign in first") { signIn = true }.font(.callout)
                    Button("Not now", role: .cancel) { model.pendingInvite = nil }.font(.callout)
                }
                .padding(24)
            }
            .sheet(isPresented: $signIn) { SignInView(domainHint: invite.domain) }
            .task { await load() }
        }
    }

    func load() async {
        loadError = nil
        if invite.domain == "demo.belfry.sh" {
            info = InviteInfo(community: "Riverside Commons", channel: "garden-3f2a", channelName: "Garden", about: "Beds, seeds and the watering rota",
                              inviter: "Ana Silva", state: "open", days: 30)
            return
        }
        let cfg = (try? await Discovery.fetch(domain: invite.domain)) ?? .defaults(domain: invite.domain)
        do { info = try await BelfryAPI(config: cfg, signer: nil).inviteInfo(invite.token) }
        catch let e as ApiError { loadError = e.message }
        catch { loadError = BelfryAPI.generic }
    }
}

/// Signed in and a guest link was opened: this account gets the channel (no second account).
struct JoinWithAccountSheet: View {
    @EnvironmentObject var model: AppModel
    let invite: PendingInvite
    @State private var info: InviteInfo?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if invite.domain != model.config.domain {
                    Label("This invite is for another community (\(invite.domain)). Sign out first to use it.", systemImage: "exclamationmark.triangle")
                } else {
                    if let info {
                        Text("Join \(info.channelName)").font(.title2.bold())
                        if !info.inviter.isEmpty { Text("\(info.inviter) invited you.").foregroundStyle(.secondary) }
                        if let closed = info.closedMessage { Label(closed, systemImage: "xmark.octagon").foregroundStyle(.red) }
                    } else {
                        Text("Join with your account").font(.title2.bold())
                    }
                    if info?.closedMessage == nil {
                        BusyButton {
                            error = await model.joinWithAccount(invite.token)
                        } label: { Text("Join with your account").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    }
                    if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                }
                Spacer()
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { model.pendingInvite = nil } } }
            .task {
                guard invite.domain == model.config.domain, !model.isDemo else { return }
                info = try? await model.api.inviteInfo(invite.token)
            }
        }
        .presentationDetents([.medium])
    }
}
