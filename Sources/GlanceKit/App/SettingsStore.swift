// OWNER: App worker.
import Foundation
import Combine

/// Settings persisted as JSON in UserDefaults. Mutations apply live via `onChange`.
public final class SettingsStore: ObservableObject {
    static let key = "glance.settings.v1"
    private let defaults: UserDefaults

    @Published public var settings: Settings {
        didSet { if settings != oldValue { persist(); onChange?(oldValue, settings) } }
    }
    public var onChange: ((Settings, Settings) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(Settings.self, from: data) {
            settings = s
        } else {
            settings = Settings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}

extension Settings {
    /// The mapper mirrors the tracking mode and eye/head weight from Settings.
    public func apply(to mapper: GazeMapper) {
        mapper.gazeMode = gazeMode
        mapper.eyeWeight = eyeWeight
    }
}
