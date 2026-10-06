import Foundation

/// A snapshot of user preferences. A running session keeps its original budget.
public struct PreparationPreferences: Sendable, Equatable {
    public static let maximumGiBKey = "preparationMaximumGiB"
    public static let retainAllKey = "preparationRetainAll"
    public static let windowSecondsKey = "preparationWindowSeconds"
    public static let remuxCacheKey = "preparationExperimentalRemuxCache"
    public let remuxCache: Bool
    public let maximumBytes: Int64
    public let retainAll: Bool
    public let windowSeconds: Double

    public init(maximumBytes: Int64 = 2 * 1024 * 1024 * 1024,
                retainAll: Bool = false, windowSeconds: Double = 60, remuxCache: Bool = false) {
        self.maximumBytes = max(1, maximumBytes)
        self.retainAll = retainAll
        self.remuxCache = remuxCache
        self.windowSeconds = windowSeconds.isFinite ? min(600, max(12, windowSeconds)) : 60
    }

    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        let value = defaults.object(forKey: maximumGiBKey) as? NSNumber
        let gib = min(64, max(1, value?.intValue ?? 2))
        let window = (defaults.object(forKey: windowSecondsKey) as? NSNumber)?.doubleValue ?? 60
        return Self(maximumBytes: Int64(gib) * 1024 * 1024 * 1024,
                    retainAll: defaults.bool(forKey: retainAllKey), windowSeconds: window,
                    remuxCache: defaults.bool(forKey: remuxCacheKey))
    }
}
