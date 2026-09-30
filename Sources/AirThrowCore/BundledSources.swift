import Foundation

extension SourceRegistry {
    private static let bundledManifests: Result<[YTDLPSourceManifest], SourceRegistryError> = {
        let directory: URL?
        if let packaged = Bundle.main.url(forResource: "SourceProviders", withExtension: nil) {
            directory = packaged
        } else {
            #if SWIFT_PACKAGE
            directory = Bundle.module.url(forResource: "SourceProviders", withExtension: nil)
            #else
            directory = nil
            #endif
        }
        guard let directory else { return .failure(.unavailableManifests) }
        do { return .success(try YTDLPSourceManifest.load(from: directory)) }
        catch { return .failure((error as? SourceRegistryError) ?? .invalidManifest) }
    }()

    /// Construct the shipped website registry, optionally registering custom
    /// Swift adapters. Duplicate IDs or hosts are errors rather than overrides.
    public static func bundled(environment: [String: String] = ProcessInfo.processInfo.environment,
                               cookies: YouTubeCookies? = nil,
                               additionalAdapters: [any SourceAdapter] = []) throws -> SourceRegistry {
        let manifests = try bundledManifests.get()
        let extracted = manifests.map { YTDLPSourceAdapter(manifest: $0, environment: environment) }
        return try SourceRegistry(adapters: customAdapters(environment: environment, cookies: cookies)
                                  + extracted + additionalAdapters)
    }
    // Register source adapters that need custom Swift discovery here. Manifest
    // providers are discovered automatically from the bundled directory.
    private static func customAdapters(environment: [String: String],
                                       cookies: YouTubeCookies?) -> [any SourceAdapter] {
        [YouTubeSourceAdapter(environment: environment, cookies: cookies)]
    }
}
