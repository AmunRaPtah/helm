import SwiftUI
import UIKit

// MARK: - Palette
//
// "Instrument panel": obsidian surfaces, steel-white type, one phosphor-lime
// signal accent. Lime is reserved for primary actions, live state, selection
// and the needle. Everything else is greyscale or a status colour.

enum HelmColor {
    // Surfaces, darkest to lightest.
    static let obsidian = Color(hex: 0x07090B)
    static let surface = Color(hex: 0x0E1116)
    static let raised = Color(hex: 0x161A21)
    static let raisedHigh = Color(hex: 0x1D222B)

    // Hairlines.
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.11)

    // Text.
    static let textPrimary = Color(hex: 0xE8ECF1)
    static let textSecondary = Color(hex: 0x8A93A0)
    static let textTertiary = Color(hex: 0x5B6573)

    // Signal.
    static let lime = Color(hex: 0xC6F432)
    static let limeDeep = Color(hex: 0xA6E022)
    static let limeGlow = Color(hex: 0xEAFF8A)
    /// Ink used on top of lime fills.
    static let onLime = Color(hex: 0x0B0F03)

    // Status.
    static let amber = Color(hex: 0xF5B14C)
    static let red = Color(hex: 0xF0605A)

    static var limeGradient: LinearGradient {
        LinearGradient(colors: [limeDeep, lime, limeGlow], startPoint: .bottomLeading, endPoint: .topTrailing)
    }

    static var cardHighlight: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
    }

    static func uiColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

// MARK: - Type

enum HelmFont {
    static let screenTitle = Font.system(.title2, design: .default, weight: .bold)
    static let headline = Font.system(.headline, design: .default, weight: .semibold)
    static let rowTitle = Font.system(.body, design: .default, weight: .semibold)
    static let body = Font.system(.body)
    static let callout = Font.system(.callout)
    static let caption = Font.system(.caption)

    /// SF Mono, for metadata, paths, tokens, timestamps and code.
    static func mono(_ style: Font.TextStyle = .caption, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

// MARK: - Spacing, radii, motion

enum HelmSpace {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 36
}

enum HelmRadius {
    static let chip: CGFloat = 8
    static let control: CGFloat = 12
    static let card: CGFloat = 14
    static let sheet: CGFloat = 22
}

enum HelmMotion {
    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.85)
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 0.9)
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.88)

    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The animation to use, or nil when Reduce Motion is on.
    static func animation(_ a: Animation = spring) -> Animation? { reduced ? nil : a }

    /// Message and card entrance.
    static var appear: AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.985, anchor: .top))
    }
}

/// `withAnimation` that honours Reduce Motion.
@discardableResult
func withHelmAnimation<Result>(_ animation: Animation = HelmMotion.spring, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(HelmMotion.animation(animation), body)
}

// MARK: - Appearance (UIKit chrome)

enum HelmAppearance {
    static func install() {
        let bg = HelmColor.uiColor(0x07090B, alpha: 0.82)
        let primary = HelmColor.uiColor(0xE8ECF1)
        let secondary = HelmColor.uiColor(0x5B6573)
        let lime = HelmColor.uiColor(0xC6F432)
        let hairline = UIColor.white.withAlphaComponent(0.07)

        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        nav.backgroundColor = bg
        nav.shadowColor = hairline
        nav.titleTextAttributes = [
            .foregroundColor: primary,
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: primary,
            .font: UIFont.systemFont(ofSize: 32, weight: .bold),
            .kern: -0.6,
        ]
        let scrollEdge = UINavigationBarAppearance()
        scrollEdge.configureWithTransparentBackground()
        scrollEdge.titleTextAttributes = nav.titleTextAttributes
        scrollEdge.largeTitleTextAttributes = nav.largeTitleTextAttributes
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdge

        let tab = UITabBarAppearance()
        tab.configureWithTransparentBackground()
        tab.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        tab.backgroundColor = bg
        tab.shadowColor = hairline
        for item in [tab.stackedLayoutAppearance, tab.inlineLayoutAppearance, tab.compactInlineLayoutAppearance] {
            item.normal.iconColor = secondary
            item.normal.titleTextAttributes = [.foregroundColor: secondary, .font: UIFont.systemFont(ofSize: 10, weight: .medium)]
            item.selected.iconColor = lime
            item.selected.titleTextAttributes = [.foregroundColor: lime, .font: UIFont.systemFont(ofSize: 10, weight: .semibold)]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        UITableView.appearance().backgroundColor = .clear
        UIRefreshControl.appearance().tintColor = lime
    }
}

// MARK: - Background

/// The obsidian backdrop: a faint top lift and a whisper of lime from the needle's corner.
struct HelmBackground: View {
    var body: some View {
        ZStack {
            HelmColor.obsidian
            LinearGradient(colors: [HelmColor.surface, HelmColor.obsidian], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45))
            RadialGradient(colors: [HelmColor.lime.opacity(0.045), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Obsidian screen background for List/Form/ScrollView screens.
    func helmScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { HelmBackground() }
    }

    /// Raised card: surface fill, continuous corners, hairline with a top highlight.
    func helmCard(radius: CGFloat = HelmRadius.card, fill: Color = HelmColor.raised, stroke: Color? = nil) -> some View {
        modifier(HelmCardModifier(radius: radius, fill: fill, stroke: stroke))
    }

    /// Row background for inset-grouped Lists and Forms.
    func helmRow() -> some View {
        listRowBackground(HelmColor.raised)
    }

    /// Animation that is dropped when Reduce Motion is on.
    func helmAnimation<V: Equatable>(_ animation: Animation = HelmMotion.spring, value: V) -> some View {
        modifier(HelmAnimationModifier(animation: animation, value: value))
    }
}

struct HelmCardModifier: ViewModifier {
    var radius: CGFloat
    var fill: Color
    var stroke: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(fill))
            .overlay {
                if let stroke {
                    shape.strokeBorder(stroke, lineWidth: 1)
                } else {
                    shape.strokeBorder(HelmColor.cardHighlight, lineWidth: 1)
                }
            }
    }
}

struct HelmAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

// MARK: - Button styles

/// Lime capsule for the one primary action on a screen.
struct HelmPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HelmFont.headline)
            .foregroundStyle(isEnabled ? HelmColor.onLime : HelmColor.textTertiary)
            .padding(.vertical, 14)
            .padding(.horizontal, 22)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .background {
                Capsule().fill(isEnabled ? AnyShapeStyle(HelmColor.limeGradient) : AnyShapeStyle(HelmColor.raised))
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(isEnabled ? 0.28 : 0.08), lineWidth: 0.75)
            }
            .shadow(color: HelmColor.lime.opacity(isEnabled ? (configuration.isPressed ? 0.15 : 0.32) : 0), radius: 16, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .helmAnimation(HelmMotion.snappy, value: configuration.isPressed)
            .helmAnimation(HelmMotion.spring, value: isEnabled)
    }
}

/// Hairline-bordered secondary button.
struct HelmSecondaryButtonStyle: ButtonStyle {
    var tint: Color = HelmColor.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Capsule().fill(HelmColor.raisedHigh))
            .overlay(Capsule().strokeBorder(HelmColor.hairlineStrong, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .helmAnimation(HelmMotion.snappy, value: configuration.isPressed)
    }
}

/// Plain press feedback for tappable cards.
struct HelmPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .helmAnimation(HelmMotion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Live state

/// A dot that emits a slow phosphor ring while active.
struct PulseDot: View {
    var color: Color = HelmColor.lime
    var size: CGFloat = 8
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if isActive && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                    let period = 1.6
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                    Circle()
                        .fill(color)
                        .frame(width: size, height: size)
                        .scaleEffect(1 + 1.6 * t)
                        .opacity(0.55 * (1 - t))
                }
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: isActive ? color.opacity(0.8) : .clear, radius: isActive ? size * 0.5 : 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension SessionState {
    var tint: Color {
        switch self {
        case .running: return HelmColor.lime
        case .starting: return HelmColor.amber
        case .idle: return HelmColor.textSecondary
        case .exited, .unknown: return HelmColor.textTertiary
        }
    }

    var label: String {
        switch self {
        case .running: return "RUNNING"
        case .starting: return "STARTING"
        case .idle: return "IDLE"
        case .exited: return "EXITED"
        case .unknown: return "UNKNOWN"
        }
    }

    var isLive: Bool { self == .running || self == .starting }
}

/// Compact mono state capsule: dot + label.
struct StatePill: View {
    let state: SessionState
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            PulseDot(color: state.tint, size: 6, isActive: state.isLive)
            if !compact {
                Text(state.label)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
            }
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(state.tint.opacity(state.isLive ? 0.12 : 0.08)))
        .overlay(Capsule().strokeBorder(state.tint.opacity(0.22), lineWidth: 0.5))
        .helmAnimation(HelmMotion.spring, value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.rawValue)
    }
}

/// Small mono metadata tag.
struct MonoTag: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = HelmColor.textSecondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            }
            Text(text).lineLimit(1)
        }
        .font(HelmFont.mono(.caption2, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(HelmColor.hairline, lineWidth: 0.5))
    }
}

/// Three phosphor bars sweeping like a level meter. Used for "working".
struct ThinkingIndicator: View {
    var color: Color = HelmColor.lime
    var label: String? = "Working"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                bars(phase: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                    bars(phase: ctx.date.timeIntervalSinceReferenceDate)
                }
            }
            if let label {
                Text(label)
                    .font(HelmFont.mono(.caption, weight: .medium))
                    .foregroundStyle(HelmColor.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Capsule().fill(HelmColor.raised))
        .overlay(Capsule().strokeBorder(HelmColor.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
    }

    private func bars(phase: Double) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                let v = reduceMotion ? 0.6 : (sin(phase * 5.2 - Double(i) * 0.9) + 1) / 2
                Capsule()
                    .fill(color.opacity(0.35 + 0.65 * v))
                    .frame(width: 3, height: 5 + 9 * v)
                    .shadow(color: color.opacity(0.5 * v), radius: 3)
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Brand

/// The helm-wheel mark from the launch screen, optionally with a lime halo.
struct HelmMark: View {
    var size: CGFloat = 72
    var glow = true

    var body: some View {
        Image("LaunchLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .background {
                if glow {
                    RadialGradient(colors: [HelmColor.lime.opacity(0.18), .clear],
                                   center: .center, startRadius: 0, endRadius: size * 0.7)
                        .frame(width: size * 1.6, height: size * 1.6)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Empty state built on the mark: mark, title, one line, optional action.
struct HelmEmptyState<Actions: View>: View {
    let title: String
    let message: String
    let showMark: Bool
    let systemImage: String?
    let actions: () -> Actions

    @State private var shown = false

    init(title: String, message: String, showMark: Bool = true, systemImage: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.message = message
        self.showMark = showMark
        self.systemImage = systemImage
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 14) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(HelmColor.textSecondary)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(HelmColor.raised))
                    .overlay(Circle().strokeBorder(HelmColor.hairline, lineWidth: 1))
            } else if showMark {
                HelmMark(size: 84)
            }
            VStack(spacing: 6) {
                Text(title)
                    .font(HelmFont.headline)
                    .foregroundStyle(HelmColor.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(HelmColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            actions()
                .padding(.top, 4)
        }
        .padding(HelmSpace.xl)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 6)
        .onAppear { withHelmAnimation(HelmMotion.gentle) { shown = true } }
    }
}

extension HelmEmptyState where Actions == EmptyView {
    init(title: String, message: String, showMark: Bool = true, systemImage: String? = nil) {
        self.init(title: title, message: message, showMark: showMark, systemImage: systemImage) { EmptyView() }
    }
}

/// Mono uppercase section label, e.g. for Form/List section headers.
struct HelmSectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(HelmColor.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(HelmFont.mono(.caption2))
                    .foregroundStyle(HelmColor.textTertiary)
            }
        }
    }
}

// MARK: - Loading

/// Shimmering placeholder block.
struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var radius: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if reduceMotion {
                shape.fill(Color.white.opacity(0.06))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                    shape.fill(Color.white.opacity(0.05 + 0.04 * sin(t * .pi)))
                }
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// A list-row-shaped skeleton: badge, two text lines.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonBlock(width: 40, height: 40, radius: 11)
            VStack(alignment: .leading, spacing: 8) {
                SkeletonBlock(width: 170, height: 12)
                SkeletonBlock(width: 110, height: 9)
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }
}
