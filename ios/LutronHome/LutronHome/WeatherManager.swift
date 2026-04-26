import Foundation
import Observation

@Observable
class WeatherManager: @unchecked Sendable {
    var currentTemp: Double?       // °F
    var conditionIcon: String = "cloud"
    var conditionLabel: String = "OUTSIDE"

    private let lat = SunCalculator.latitude
    private let lon = SunCalculator.longitude

    func resume() {
        Task {
            do {
                let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code&temperature_unit=fahrenheit")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("WeatherManager: bad status")
                    return
                }
                let json = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                let code = json.current.weather_code
                let temp = json.current.temperature_2m

                await MainActor.run {
                    self.currentTemp = temp
                    self.conditionIcon = sfSymbol(for: code)
                    self.conditionLabel = shortLabel(for: code)
                }
            } catch {
                print("WeatherManager: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Open-Meteo Response

    private struct OpenMeteoResponse: Decodable {
        let current: Current
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
    }

    // MARK: - WMO Weather Code Mapping
    // https://open-meteo.com/en/docs — WMO Weather interpretation codes

    private func sfSymbol(for code: Int) -> String {
        switch code {
        case 0:             return "sun.max"           // Clear sky
        case 1:             return "sun.max"           // Mainly clear
        case 2:             return "cloud.sun"         // Partly cloudy
        case 3:             return "cloud"             // Overcast
        case 45, 48:        return "cloud.fog"         // Fog
        case 51, 53, 55:    return "cloud.drizzle"     // Drizzle
        case 56, 57:        return "cloud.sleet"       // Freezing drizzle
        case 61, 63, 65:    return "cloud.rain"        // Rain
        case 66, 67:        return "cloud.sleet"       // Freezing rain
        case 71, 73, 75:    return "cloud.snow"        // Snow
        case 77:            return "cloud.snow"        // Snow grains
        case 80, 81, 82:    return "cloud.rain"        // Rain showers
        case 85, 86:        return "cloud.snow"        // Snow showers
        case 95:            return "cloud.bolt.rain"   // Thunderstorm
        case 96, 99:        return "cloud.bolt.rain"   // Thunderstorm with hail
        default:            return "cloud"
        }
    }

    private func shortLabel(for code: Int) -> String {
        switch code {
        case 0, 1:          return "CLEAR"
        case 2:             return "PT CLOUDY"
        case 3:             return "CLOUDY"
        case 45, 48:        return "FOG"
        case 51, 53, 55:    return "DRIZZLE"
        case 56, 57:        return "FRZ DRZL"
        case 61, 63, 65:    return "RAIN"
        case 66, 67:        return "FRZ RAIN"
        case 71, 73, 75:    return "SNOW"
        case 77:            return "SNOW"
        case 80, 81, 82:    return "SHOWERS"
        case 85, 86:        return "SNOW"
        case 95:            return "STORMS"
        case 96, 99:        return "STORMS"
        default:            return "OUTSIDE"
        }
    }
}
