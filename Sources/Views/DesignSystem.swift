import SwiftUI
import AppKit

// MARK: - Colors (Dieter Rams / Braun DR06 Palette)

enum SeminarlyColors {
    // Primary accent — warm orange (#ED8008)
    static let accent = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.94, green: 0.56, blue: 0.19, alpha: 1) // #F09030
            : NSColor(red: 0.93, green: 0.50, blue: 0.03, alpha: 1) // #ED8008
    }))

    // Recording / active state — red-orange (#ED3F1C)
    static let recording = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.94, green: 0.33, blue: 0.21, alpha: 1) // #F05535
            : NSColor(red: 0.93, green: 0.25, blue: 0.11, alpha: 1) // #ED3F1C
    }))

    // Destructive / alert — deep red (#BF1B1B)
    static let destructive = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.83, green: 0.19, blue: 0.19, alpha: 1) // #D43030
            : NSColor(red: 0.75, green: 0.11, blue: 0.11, alpha: 1) // #BF1B1B
    }))

    // Success / confirmation — olive moss (#736B1E)
    static let success = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.56, green: 0.52, blue: 0.19, alpha: 1) // #8E8530
            : NSColor(red: 0.45, green: 0.42, blue: 0.12, alpha: 1) // #736B1E
    }))

    // Surfaces
    static let surface = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.16, green: 0.16, blue: 0.14, alpha: 1) // #2A2824
            : NSColor(red: 0.85, green: 0.82, blue: 0.78, alpha: 1) // #D9D2C6
    }))

    static let surfaceElevated = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.21, green: 0.20, blue: 0.19, alpha: 1) // #353230
            : NSColor(red: 0.94, green: 0.92, blue: 0.89, alpha: 1) // #EFEBE4
    }))

    static let background = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1) // #1E1C1A
            : NSColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1) // #F5F2ED
    }))

    // Text
    static let textPrimary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.91, green: 0.89, blue: 0.87, alpha: 1) // #E8E4DD
            : NSColor(red: 0.17, green: 0.16, blue: 0.15, alpha: 1) // #2C2A26
    }))

    static let textSecondary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.62, green: 0.60, blue: 0.54, alpha: 1) // #9E9889
            : NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1) // #6B665C
    }))

    static let textTertiary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.42, green: 0.40, blue: 0.36, alpha: 1) // #6B665C
            : NSColor(red: 0.62, green: 0.60, blue: 0.54, alpha: 1) // #9E9889
    }))

    // Sidebar selection — exact #CFCECE light, subtle warm dark
    static let sidebarSelection = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.22, green: 0.21, blue: 0.20, alpha: 1) // #383533
            : NSColor(red: 0.812, green: 0.808, blue: 0.808, alpha: 1) // #CFCECE
    }))

    // Borders
    static let border = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.24, green: 0.23, blue: 0.21, alpha: 1) // #3D3A36
            : NSColor(red: 0.82, green: 0.80, blue: 0.75, alpha: 1) // #D1CBBF
    }))

    static let borderSubtle = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.18, green: 0.18, blue: 0.16, alpha: 1) // #2F2D2A
            : NSColor(red: 0.89, green: 0.87, blue: 0.83, alpha: 1) // #E2DDD4
    }))
}

// MARK: - Spacing (4pt Grid)

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

// MARK: - Typography

enum Typography {
    static let largeTitle: Font = .system(size: 22, weight: .semibold)
    static let title: Font = .system(size: 17, weight: .semibold)
    static let headline: Font = .system(size: 14, weight: .semibold)
    static let body: Font = .system(size: 13, weight: .regular)
    static let bodyMedium: Font = .system(size: 13, weight: .medium)
    static let caption: Font = .system(size: 11, weight: .regular)
    static let captionMedium: Font = .system(size: 11, weight: .medium)
    static let mono: Font = .system(size: 12, weight: .regular, design: .monospaced)
}

// MARK: - Card Modifier

struct SeminarlyCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(SeminarlyColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SeminarlyColors.border, lineWidth: 0.5)
            )
    }
}

extension View {
    func seminarlyCard() -> some View {
        modifier(SeminarlyCardModifier())
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Speaker Palette (Accessible)

struct SpeakerIdentity {
    let color: Color
    let shape: String
    let label: String
}

enum SpeakerPalette {
    private static let identities: [SpeakerIdentity] = [
        SpeakerIdentity(color: SeminarlyColors.accent, shape: "circle.fill", label: "You"),
        SpeakerIdentity(
            color: Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0.45, green: 0.62, blue: 0.52, alpha: 1)
                    : NSColor(red: 0.36, green: 0.54, blue: 0.45, alpha: 1) // #5B8A72 sage
            })),
            shape: "triangle.fill",
            label: "A"
        ),
        SpeakerIdentity(
            color: Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0.62, green: 0.50, blue: 0.38, alpha: 1)
                    : NSColor(red: 0.55, green: 0.44, blue: 0.31, alpha: 1) // #8B6F4E warm brown
            })),
            shape: "diamond.fill",
            label: "B"
        ),
        SpeakerIdentity(
            color: Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0.50, green: 0.55, blue: 0.63, alpha: 1)
                    : NSColor(red: 0.42, green: 0.48, blue: 0.55, alpha: 1) // #6B7B8D slate
            })),
            shape: "square.fill",
            label: "C"
        ),
        SpeakerIdentity(
            color: Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0.68, green: 0.48, blue: 0.55, alpha: 1)
                    : NSColor(red: 0.61, green: 0.42, blue: 0.48, alpha: 1) // #9B6B7B dusty rose
            })),
            shape: "pentagon.fill",
            label: "D"
        ),
        SpeakerIdentity(
            color: Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                    ? NSColor(red: 0.55, green: 0.55, blue: 0.42, alpha: 1)
                    : NSColor(red: 0.48, green: 0.48, blue: 0.36, alpha: 1) // #7B7B5B khaki
            })),
            shape: "hexagon.fill",
            label: "E"
        ),
    ]

    static func identity(for speaker: String) -> SpeakerIdentity {
        if speaker == "You" { return identities[0] }

        // Extract number from "Speaker N" pattern
        if let number = speaker.split(separator: " ").last.flatMap({ Int($0) }) {
            let index = ((number - 1) % (identities.count - 1)) + 1
            return identities[index]
        }

        // Fallback: hash-based index for unexpected speaker names
        let hash = abs(speaker.hashValue)
        let index = (hash % (identities.count - 1)) + 1
        return identities[index]
    }
}

// MARK: - Empty State

struct SeminarlyEmptyState<Accessory: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?
    /// Optional quiet content shown beneath the primary action (e.g. a secondary
    /// link-style offer). Defaults to nothing via the `EmptyView` convenience init.
    @ViewBuilder var accessory: () -> Accessory

    init(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(SeminarlyColors.textTertiary)

            Text(title)
                .font(Typography.title)
                .foregroundStyle(SeminarlyColors.textSecondary)

            if let subtitle {
                Text(subtitle)
                    .font(Typography.body)
                    .foregroundStyle(SeminarlyColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(Typography.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.sm)
                        .background(SeminarlyColors.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            accessory()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension SeminarlyEmptyState where Accessory == EmptyView {
    init(
        symbol: String,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            actionTitle: actionTitle,
            action: action,
            accessory: { EmptyView() }
        )
    }
}
