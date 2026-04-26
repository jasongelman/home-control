import SwiftUI

struct EditorialHeroSection: View {
    private let period = SunCalculator.currentPeriod()

    var body: some View {
        let (word1, word2) = heroWords

        (Text(word1).foregroundColor(EditorialTheme.primaryText) +
         Text(" ") +
         Text(word2).foregroundColor(EditorialTheme.heroAccent()))
            .font(EditorialTheme.bebasNeue(size: 48))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
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
