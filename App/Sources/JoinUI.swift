import BelfryCore
import SwiftUI

// Guest links (SPEC 19.4, 19.26): https://chat.<domain>/join/<token> opens the app (universal
// link). Signed out: straight into the channel in guest mode (GuestUI.swift, AppModel+Guest).
// Signed in: "Join with your account" here. Only the link's domain and token are read; everything
// shown comes from the belfry's answer or is a fixed text.

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
