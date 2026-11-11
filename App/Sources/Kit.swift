import BelfryCore
import SwiftUI

// Shared pieces that carry the owner's UI rules (CLAUDE.md "UI rules"):
// - every button locks the moment it is tapped and shows progress until its work is done
//   (BusyButton; a second tap within 600 ms is swallowed even after the work ended);
// - menus and sheets are Discord-style grouped lists with a line icon (ActionRow);
// - a pod's mark is a polygon with one side per member (PodShape).

/// A button that runs ACTION once: disabled with a spinner until it returns.
struct BusyButton<Label: View>: View {
    var role: ButtonRole?
    let action: () async -> Void
    @ViewBuilder let label: () -> Label
    @State private var busy = false
    @State private var lastTap = Date.distantPast

    init(role: ButtonRole? = nil, action: @escaping () async -> Void, @ViewBuilder label: @escaping () -> Label) {
        self.role = role
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(role: role) {
            guard !busy, Date().timeIntervalSince(lastTap) > 0.6 else { return }
            lastTap = Date()
            busy = true
            Task { @MainActor in
                await action()
                busy = false
            }
        } label: {
            HStack(spacing: 8) {
                label()
                if busy { ProgressView().controlSize(.small) }
            }
        }
        .disabled(busy)
    }
}

extension BusyButton where Label == Text {
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () async -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

/// One row of a Discord-style action list: a line icon, a title, an optional detail.
struct ActionRow: View {
    let icon: String
    let title: String
    var detail: String?
    var destructive = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.body)
                .frame(width: 24)
                .foregroundStyle(destructive ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(destructive ? Color.red : Color.primary)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// A row that runs an action once (locks with a spinner).
struct ActionButtonRow: View {
    let icon: String
    let title: String
    var detail: String?
    var destructive = false
    let action: () async -> Void
    var body: some View {
        BusyButton(role: destructive ? .destructive : nil, action: action) {
            ActionRow(icon: icon, title: title, detail: detail, destructive: destructive)
        }
        .buttonStyle(.plain)
    }
}

/// A regular polygon with SIDES sides, point up (3: a triangle a little lower), or a circle.
struct PodShape: Shape {
    let members: Int
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let scale = s / 24
        if PodShapes.isCircle(members) {
            return Path(ellipseIn: CGRect(x: rect.midX - 9 * scale, y: rect.midY - 9 * scale, width: 18 * scale, height: 18 * scale))
        }
        let n = PodShapes.sides(members)
        let r = 9.5 * scale
        let cx = rect.midX
        let cy = rect.midY + (n == 3 ? 1.5 * scale : 0)
        var p = Path()
        for i in 0..<n {
            let a = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(n)
            let pt = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// A channel's mark: #, 📅, 📝 or the pod's shape.
struct ChannelGlyph: View {
    let group: Channel
    var size: CGFloat = 20
    var body: some View {
        if group.isPod {
            PodShape(members: group.members.count)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .frame(width: size, height: size)
                .accessibilityLabel("Pod")
        } else {
            Text(group.icon).font(.system(size: size * 0.85, weight: .semibold)).frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// A small rounded label.
struct Chip: View {
    let text: String
    var icon: String?
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// A sheet's title bar with a close button (a back arrow never pushes).
struct SheetHeader: View {
    let title: String
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }
                .accessibilityLabel("Close")
        }
        .padding(.horizontal).padding(.top, 16).padding(.bottom, 8)
    }
}

/// The open channel or message, from anywhere (search results, cards, links).
struct OpenChannelKey: EnvironmentKey { static let defaultValue: (String, String?) -> Void = { _, _ in } }

extension EnvironmentValues {
    var openChannel: (String, String?) -> Void {
        get { self[OpenChannelKey.self] }
        set { self[OpenChannelKey.self] = newValue }
    }
}
