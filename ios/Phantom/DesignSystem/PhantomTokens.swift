import SwiftUI
import UIKit

// MARK: - Spacing

/// 4pt base grid spacing scale.
enum PhantomSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    /// Section separation, large gaps.
    static let xxl: CGFloat = 48
    /// Safe inset from screen edge (matches Apple HIG).
    static let safe: CGFloat = 20
}

// MARK: - Corner Radii

enum PhantomRadius {
    /// Toolbar quick-keys, small interactive elements.
    static let key: CGFloat = 6
    /// Cards, panels, sheets.
    static let card: CGFloat = 10
    /// Status pills, badges — use `.capsule` shape instead for truly pill-shaped.
    static let pill: CGFloat = 100
}

// MARK: - Typography

/// Typography system using Dynamic Type for chrome, monospaced for terminal.
/// Chrome uses SF Pro Rounded for warmth; terminal uses system monospace.
enum PhantomFont {
    /// Terminal content font (monospace, fixed size — does not scale with Dynamic Type).
    static func terminal(size: CGFloat = 14) -> UIFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Chrome UI (SF Pro Rounded, Dynamic Type)

    /// Screen titles, hero text.
    static let title = Font.system(.title3, design: .rounded, weight: .semibold)
    /// Primary labels, headings.
    static let headline = Font.system(.headline, design: .rounded, weight: .medium)
    /// Body text, descriptions.
    static let body = Font.system(.subheadline, design: .rounded, weight: .regular)
    /// Secondary labels, subtitles.
    static let secondaryLabel = Font.system(.subheadline, design: .rounded, weight: .regular)
    /// Captions, tertiary information.
    static let caption = Font.system(.caption, design: .rounded, weight: .regular)
    /// Monospaced captions (fingerprints, IDs, session names).
    static let captionMono = Font.system(.caption, design: .monospaced, weight: .medium)
    /// Toolbar key labels (monospace for chrome keys).
    static let keyLabel = Font.system(.footnote, design: .monospaced, weight: .medium)
    /// Section headers.
    static let sectionHeader = Font.system(.caption, design: .rounded, weight: .semibold)
}

// MARK: - Animation

extension Animation {
    /// Panel slide-up reveals: fast in, gentle settle.
    static let panelReveal = Animation.easeOut(duration: 0.25)
    /// State changes (tab switch, selection): snappy, no overshoot.
    static let stateChange = Animation.easeInOut(duration: 0.15)
    /// Micro-interactions (press highlight release).
    static let subtle = Animation.easeOut(duration: 0.12)
    /// Springy feedback for user-initiated actions (drags, flicks).
    static let springy = Animation.spring(response: 0.35, dampingFraction: 0.7)
    /// Session switching, tab transitions.
    static let sessionSwitch = Animation.interactiveSpring(response: 0.3, dampingFraction: 0.85)
    /// Staggered appearance with slight delay.
    static let appear = Animation.easeOut(duration: 0.2).delay(0.05)
}

// MARK: - Chrome Colors (derived from terminal theme)

/// Semantic color tokens derived from the active terminal theme.
/// Chrome colors step up from the terminal background to create depth without shadows.
struct PhantomColors {
    /// Terminal viewport background (deepest layer).
    let base: Color
    /// Tab bar, toolbar background (middle layer).
    let surface: Color
    /// Active tab, button backgrounds (top layer).
    let elevated: Color
    /// Primary text on chrome.
    let textPrimary: Color
    /// Secondary/dimmed text.
    let textSecondary: Color
    /// Accent color (cursor, active states, success).
    let accent: Color
    /// Separator lines.
    let separator: Color

    // MARK: Semantic Status Colors

    /// Connected, success.
    var statusConnected: Color { accent }
    /// Warning, in-progress, transient states.
    var statusWarning: Color { Color(uiColor: .systemYellow) }
    /// Disconnected, error.
    var statusError: Color { Color(uiColor: .systemRed) }

    /// Derive chrome colors from a TerminalTheme.
    init(from theme: TerminalTheme) {
        let bg = theme.background
        let fg = theme.foreground

        self.base = Color(bg)

        if theme.isDark {
            // Dark themes: lighten background for surfaces
            self.surface = Color(bg.adjusted(brightness: 0.06))
            self.elevated = Color(bg.adjusted(brightness: 0.12))
            self.separator = Color(fg).opacity(0.1)
        } else {
            // Light themes: darken background for surfaces
            self.surface = Color(bg.adjusted(brightness: -0.04))
            self.elevated = Color(bg.adjusted(brightness: -0.08))
            self.separator = Color(UIColor.black).opacity(0.1)
        }

        self.textPrimary = Color(fg)
        self.textSecondary = Color(fg).opacity(0.5)
        self.accent = Color(theme.cursor)
    }

    /// Fallback dark palette when no theme is available.
    static let defaultDark = PhantomColors(
        base: Color(hex: 0x1E2430),
        surface: Color(hex: 0x252D3A),
        elevated: Color(hex: 0x2E3744),
        textPrimary: Color(hex: 0xE8ECF0),
        textSecondary: Color(hex: 0x8B95A5),
        accent: Color(hex: 0x4CAF7D),
        separator: Color.white.opacity(0.1)
    )

    private init(base: Color, surface: Color, elevated: Color,
                 textPrimary: Color, textSecondary: Color,
                 accent: Color, separator: Color) {
        self.base = base
        self.surface = surface
        self.elevated = elevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.accent = accent
        self.separator = separator
    }
}

// MARK: - Environment Key

private struct PhantomColorsKey: EnvironmentKey {
    static let defaultValue = PhantomColors.defaultDark
}

extension EnvironmentValues {
    var phantomColors: PhantomColors {
        get { self[PhantomColorsKey.self] }
        set { self[PhantomColorsKey.self] = newValue }
    }
}

// MARK: - UIColor Helpers

extension UIColor {
    /// Adjust brightness by a relative amount (-1.0 to 1.0).
    func adjusted(brightness delta: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return UIColor(hue: h, saturation: s, brightness: max(0, min(1, b + delta)), alpha: a)
    }
}

// MARK: - Color Hex Init

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
