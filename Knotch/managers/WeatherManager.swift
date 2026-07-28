//
//  WeatherManager.swift
//  Knotch
//
//  Sources weather/AQI/sunrise data for the lock-screen weather mini-widget
//  from Open-Meteo (free, keyless HTTP API) rather than WeatherKit, so this
//  feature ships without an Apple Developer portal capability step.
//

import CoreLocation
import Defaults
import Foundation

/// Which metric the weather mini-widget shows, matching the reference lock
/// screen's Conditions/Sun/Precipitation segmented picker.
enum MiniWidgetWeatherMetric: String, CaseIterable, Identifiable, Defaults.Serializable {
    case conditions = "Conditions"
    case sun = "Sun"
    case precipitation = "Precipitation"
    var id: String { rawValue }
}

struct WeatherSnapshot {
    var temperatureC: Double
    var conditionSymbol: String
    var conditionDescription: String
    var aqi: Int
    var aqiLabel: String
    var sunriseDate: Date
    var sunsetDate: Date
}

final class WeatherManager: NSObject, ObservableObject {
    static let shared = WeatherManager()

    @Published private(set) var snapshot: WeatherSnapshot?

    private let locationManager = CLLocationManager()
    private var refreshTimer: Timer?
    private var isFetching = false

    private static let refreshInterval: TimeInterval = 30 * 60

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Kicks off a location request (if authorized) and schedules periodic
    /// refreshes. Safe to call repeatedly — e.g. once on lock each time.
    func refreshIfNeeded() {
        guard Defaults[.lockScreenWeatherMiniWidget] else { return }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            locationManager.requestLocation()
        default:
            break
        }

        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
                self?.locationManager.requestLocation()
            }
        }
    }

    private func fetchSnapshot(latitude: Double, longitude: Double) {
        guard !isFetching else { return }
        isFetching = true

        Task {
            defer { isFetching = false }
            do {
                async let forecast = Self.fetchForecast(latitude: latitude, longitude: longitude)
                async let airQuality = Self.fetchAirQuality(latitude: latitude, longitude: longitude)
                let (forecastResponse, airQualityResponse) = try await (forecast, airQuality)

                guard let current = forecastResponse.current,
                      let daily = forecastResponse.daily,
                      let sunrise = daily.sunrise.first,
                      let sunset = daily.sunset.first else { return }

                let (symbol, description) = Self.symbol(forWeatherCode: current.weatherCode)
                let aqi = airQualityResponse.current?.usAqi ?? 0

                let newSnapshot = WeatherSnapshot(
                    temperatureC: current.temperature2m,
                    conditionSymbol: symbol,
                    conditionDescription: description,
                    aqi: aqi,
                    aqiLabel: Self.aqiLabel(for: aqi),
                    sunriseDate: Self.parseISODate(sunrise) ?? Date(),
                    sunsetDate: Self.parseISODate(sunset) ?? Date()
                )
                await MainActor.run { self.snapshot = newSnapshot }
            } catch {
                print("[Weather] Fetch failed: \(error)")
            }
        }
    }

    // MARK: - Open-Meteo requests

    private static func fetchForecast(latitude: Double, longitude: Double) async throws -> OpenMeteoForecastResponse {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(OpenMeteoForecastResponse.self, from: data)
    }

    private static func fetchAirQuality(latitude: Double, longitude: Double) async throws -> OpenMeteoAirQualityResponse {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "us_aqi"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        return try JSONDecoder().decode(OpenMeteoAirQualityResponse.self, from: data)
    }

    // MARK: - Mapping helpers

    /// Maps Open-Meteo's WMO weather codes to an SF Symbol + short description.
    private static func symbol(forWeatherCode code: Int) -> (symbol: String, description: String) {
        switch code {
        case 0: return ("sun.max.fill", "Clear")
        case 1, 2: return ("cloud.sun.fill", "Partly Cloudy")
        case 3: return ("cloud.fill", "Cloudy")
        case 45, 48: return ("cloud.fog.fill", "Foggy")
        case 51, 53, 55, 56, 57: return ("cloud.drizzle.fill", "Drizzle")
        case 61, 63, 65, 66, 67: return ("cloud.rain.fill", "Rain")
        case 71, 73, 75, 77: return ("cloud.snow.fill", "Snow")
        case 80, 81, 82: return ("cloud.heavyrain.fill", "Showers")
        case 85, 86: return ("cloud.snow.fill", "Snow Showers")
        case 95, 96, 99: return ("cloud.bolt.rain.fill", "Thunderstorm")
        default: return ("cloud.fill", "—")
        }
    }

    /// US EPA AQI breakpoints.
    private static func aqiLabel(for aqi: Int) -> String {
        switch aqi {
        case ..<51: return "Good"
        case 51..<101: return "Moderate"
        case 101..<151: return "Unhealthy for Sensitive Groups"
        case 151..<201: return "Unhealthy"
        case 201..<301: return "Very Unhealthy"
        default: return "Hazardous"
        }
    }

    private static func parseISODate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.timeZone = .current
        return formatter.date(from: string)
    }
}

extension WeatherManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        fetchSnapshot(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[Weather] Location request failed: \(error)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorized {
            manager.requestLocation()
        }
    }
}

// MARK: - Open-Meteo response models

private struct OpenMeteoForecastResponse: Decodable {
    struct Current: Decodable {
        let temperature2m: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case weatherCode = "weather_code"
        }
    }
    struct Daily: Decodable {
        let sunrise: [String]
        let sunset: [String]
    }
    let current: Current?
    let daily: Daily?
}

private struct OpenMeteoAirQualityResponse: Decodable {
    struct Current: Decodable {
        let usAqi: Int?
        enum CodingKeys: String, CodingKey {
            case usAqi = "us_aqi"
        }
    }
    let current: Current?
}
