import SwiftUI

// MARK: - Section label

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.cueSectionLabel)
            .foregroundStyle(Theme.tertiaryText)
            .kerning(0.6)
    }
}

// MARK: - Glass segmented control (Screen / Window / Area)

struct Segment<T: Hashable>: Identifiable {
    let value: T
    let title: String
    var systemImage: String?
    var id: T { value }

    init(_ value: T, _ title: String, systemImage: String? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
    }
}

struct GlassSegmentedControl<T: Hashable>: View {
    let segments: [Segment<T>]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments) { seg in
                let isSelected = seg.value == selection
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        selection = seg.value
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let img = seg.systemImage {
                            Image(systemName: img).font(.system(size: 11, weight: .semibold))
                        }
                        Text(seg.title)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(.thinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(.white.opacity(0.18), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "selectedSegment", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - On / Off pill

struct OnOffPill: View {
    let isOn: Bool
    var onLabel: String = "On"
    var offLabel: String = "Off"

    var body: some View {
        Text(isOn ? onLabel : offLabel)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(isOn ? Theme.teal : Theme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((isOn ? Theme.teal : Color.secondary).opacity(0.16))
            )
            .animation(.easeInOut(duration: 0.18), value: isOn)
    }
}

// MARK: - Control row shell (used for the camera & mic pickers)

struct ControlRow<Center: View, Trailing: View>: View {
    let systemImage: String
    var iconColor: Color = Theme.secondaryText
    @ViewBuilder var center: () -> Center
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            center()
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .liquidGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}

// MARK: - Glass card

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = Theme.Radius.card
    var padding: CGFloat = Theme.Spacing.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Recording dot (pulsing)

struct RecordingDot: View {
    var size: CGFloat = 8
    var paused: Bool = false
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(paused ? Theme.secondaryText : Theme.recording)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Theme.recording.opacity(0.55), lineWidth: 1.5)
                    .scaleEffect(pulse && !paused ? 2.4 : 1)
                    .opacity(pulse && !paused ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Footer icon action (Effects / Notes / Library style)

struct FooterAction: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 34, height: 34)
                    .liquidGlass(in: Circle(), interactive: true)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
