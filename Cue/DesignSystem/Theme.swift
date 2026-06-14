import SwiftUI

/// Central design tokens for Cue.
///
/// The visual language leans on Apple's Liquid Glass (macOS 26+) with a
/// graceful translucent-material fallback on macOS 15. Accent is an electric
/// blue / deep teal pairing to stay clearly distinct from Loom's purple.
enum Theme {

    // MARK: Accent

    /// Primary electric-blue accent. Matches `AccentColor` in the asset catalog.
    static let accent = Color(red: 0.0, green: 0.478, blue: 1.0)

    /// Secondary deep-teal accent, used for "live"/active affordances.
    static let teal = Color(red: 0.0, green: 0.72, blue: 0.74)

    /// The unmistakable recording red.
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.27)

    static let success = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let warning = Color(red: 1.0, green: 0.71, blue: 0.20)

    // MARK: Text

    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color.secondary.opacity(0.6)

    // MARK: Layout

    enum Radius {
        static let popover: CGFloat = 22
        static let card: CGFloat = 16
        static let control: CGFloat = 12
        static let pill: CGFloat = 999
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Fixed width of the menubar popover, tuned to match the reference designs.
    static let popoverWidth: CGFloat = 320
}

// MARK: - Typography

extension Font {
    /// Bold app/section title (e.g. the "Cue" wordmark in the popover).
    static let cueTitle = Font.system(size: 17, weight: .bold, design: .rounded)
    /// Group label above a control row (e.g. "Camera", "Microphone").
    static let cueSectionLabel = Font.system(size: 11, weight: .semibold)
    /// Row title (e.g. a device name).
    static let cueRowTitle = Font.system(size: 13, weight: .medium)
    /// Prominent button label.
    static let cueButton = Font.system(size: 14, weight: .semibold, design: .rounded)
    /// Small caption / footer.
    static let cueCaption = Font.system(size: 11, weight: .medium)
}
