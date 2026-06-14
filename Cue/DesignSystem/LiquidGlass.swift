import SwiftUI
import AppKit

// MARK: - Liquid Glass, with a macOS 15 fallback
//
// On macOS 26 (Tahoe) and later we use Apple's real Liquid Glass APIs
// (`glassEffect`, `GlassEffectContainer`). On macOS 15 those symbols don't
// exist at runtime, so we fall back to a hand-tuned translucent material that
// reads as "glassy": an ultra-thin material fill, an optional accent wash, and
// a top-down edge highlight. The call sites are identical on both OS versions.

extension View {

    /// Applies a Liquid Glass background clipped to `shape`.
    /// - Parameters:
    ///   - shape: the glass silhouette (capsule, rounded rect, circle…).
    ///   - tint: optional accent tint blended into the glass.
    ///   - interactive: whether the glass should react to pointer/press (macOS 26+).
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(glassValue(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(GlassFallback(shape: shape, tint: tint))
        }
    }

    /// Convenience for a continuous rounded-rectangle glass.
    func liquidGlass(cornerRadius: CGFloat = Theme.Radius.card,
                     tint: Color? = nil,
                     interactive: Bool = false) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                    tint: tint, interactive: interactive)
    }
}

@available(macOS 26.0, *)
private func glassValue(tint: Color?, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

/// The macOS 15 stand-in for Liquid Glass.
private struct GlassFallback<S: Shape>: View {
    let shape: S
    var tint: Color?

    var body: some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            if let tint {
                shape.fill(tint.opacity(0.22))
            }
        }
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.40), Color.white.opacity(0.06)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.75
            )
        )
    }
}

// MARK: - Glass container
//
// On macOS 26 this merges nearby glass shapes so they blend/morph; on 15 it's
// a transparent pass-through. Wrap clusters of glass controls in one.

struct GlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Window-level vibrancy (popover background)

/// AppKit-backed vibrancy used as the popover's base layer. Gives the true
/// "menu material" look on every supported OS; Liquid Glass elements then sit
/// on top of it.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = emphasized
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = emphasized
    }
}

// MARK: - Button styles

/// The big, tinted call-to-action ("Start Recording").
struct ProminentGlassButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        ProminentGlassButtonBody(configuration: configuration, tint: tint)
    }

    private struct ProminentGlassButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let label = configuration.label
                .font(.cueButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .contentShape(Capsule())

            Group {
                if #available(macOS 26.0, *) {
                    label.glassEffect(.regular.tint(tint).interactive(), in: Capsule())
                } else {
                    label
                        .background(
                            LinearGradient(colors: [tint, tint.opacity(0.82)],
                                           startPoint: .top, endPoint: .bottom),
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(.white.opacity(0.22), lineWidth: 0.5))
                        .shadow(color: tint.opacity(0.42), radius: 9, y: 3)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.5)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
        }
    }
}

/// A neutral glass button used for secondary / icon actions.
struct GlassButtonStyle: ButtonStyle {
    var shape: AnyShape = AnyShape(Capsule())
    var padding: EdgeInsets = EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(padding)
            .contentShape(shape)
            .liquidGlass(in: shape, interactive: true)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ProminentGlassButtonStyle {
    static var prominentGlass: ProminentGlassButtonStyle { ProminentGlassButtonStyle() }
    static func prominentGlass(tint: Color) -> ProminentGlassButtonStyle {
        ProminentGlassButtonStyle(tint: tint)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glassControl: GlassButtonStyle { GlassButtonStyle() }
    static func glassControl(shape: AnyShape) -> GlassButtonStyle {
        GlassButtonStyle(shape: shape)
    }
}
