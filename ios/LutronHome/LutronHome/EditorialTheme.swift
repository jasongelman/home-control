import SwiftUI

/// Single source of truth for the editorial/brutalist design system.
/// All colors, fonts, and reusable view modifiers live here.
enum EditorialTheme {

    // MARK: - Colors

    static let background = Color.white
    static let accent = Color(red: 0.93, green: 0.36, blue: 0.13)       // #ED5B21
    static let primaryText = Color.black
    static let secondaryText = Color(UIColor.secondaryLabel)
    static let tertiaryText = Color(UIColor.tertiaryLabel)
    static let cardBorder = Color(UIColor.separator).opacity(0.3)
    static let cardBackground = Color(UIColor.systemGray6)

    // Climate accent bars
    static let heating = Color(red: 0.93, green: 0.36, blue: 0.13)
    static let cooling = Color(red: 0.2, green: 0.6, blue: 0.95)
    static let idle = Color(UIColor.systemGray4)

    /// Hero accent color that shifts with time of day.
    /// Orange stays dominant; subtle shift adds life.
    static func heroAccent() -> Color {
        switch SunCalculator.currentPeriod() {
        case .earlyMorning: return Color(red: 0.55, green: 0.35, blue: 0.85)
        case .morning:      return Color(red: 0.95, green: 0.65, blue: 0.15)
        case .midday:       return Color(red: 0.15, green: 0.55, blue: 0.90)
        case .evening:      return accent
        case .night:        return Color(red: 0.40, green: 0.65, blue: 1.0)
        }
    }

    // MARK: - Typography

    static func bebasNeue(size: CGFloat) -> Font {
        .custom("BebasNeue-Regular", size: size)
    }

    static func monoValue(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sectionLabel(size: CGFloat = 11) -> Font {
        .system(size: size, weight: .semibold)
    }

    // MARK: - Layout Constants

    static let cardRadius: CGFloat = 8
    static let gridSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 24
}

// MARK: - Reusable View Modifiers

struct EditorialCardModifier: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(EditorialTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: EditorialTheme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: EditorialTheme.cardRadius)
                    .stroke(EditorialTheme.cardBorder, lineWidth: 0.5)
            )
    }
}

extension View {
    func editorialCard(padding: CGFloat = 12) -> some View {
        modifier(EditorialCardModifier(padding: padding))
    }
}

// MARK: - Section Header

struct EditorialSectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(EditorialTheme.sectionLabel())
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(EditorialTheme.primaryText)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(EditorialTheme.sectionLabel(size: 10))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(EditorialTheme.secondaryText)
            }
        }
    }
}
