import SwiftUI

/// Shared building blocks for settings-style cards (settings + onboarding).

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.tertiaryText)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 13)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }
}

struct RowButton: View {
    let label: String
    let system: String
    var destructive = false
    let action: () -> Void
    init(_ label: String, system: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.label = label; self.system = system; self.destructive = destructive; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: system).frame(width: 16)
                Text(label).font(.cueRowTitle)
                Spacer()
            }
            .foregroundStyle(destructive ? Color.red : Theme.primaryText)
            .contentShape(Rectangle())
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.cueCaption)
            .foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
    }
}
