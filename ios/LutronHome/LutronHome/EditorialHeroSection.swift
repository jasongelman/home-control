import SwiftUI

struct EditorialHeroSection: View {
    private let period = SunCalculator.currentPeriod()

    var body: some View {
        let (word1, word2) = heroWords

        Text(heroAttributedString(word1: word1, word2: word2))
            .font(EditorialTheme.bebasNeue(size: 48))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroAttributedString(word1: String, word2: String) -> AttributedString {
        var part1 = AttributedString("\(word1) ")
        part1.foregroundColor = EditorialTheme.primaryText
        var part2 = AttributedString(word2)
        part2.foregroundColor = EditorialTheme.heroAccent()
        return part1 + part2
    }

    private var heroWords: (String, String) {
        switch period {
        case .earlyMorning: return ("GOOD", "MORNING.")
        case .morning:      return ("MORNING", "LIGHT.")
        case .midday:       return ("ALL", "CLEAR.")
        case .evening:      return ("EVENING", "READY.")
        case .night:        return ("GOODNIGHT", "HOUSE.")
        }
    }
}
