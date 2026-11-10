import Foundation

enum AppDataMigration {
    static let bundleIdentifier = "local.vsux.app"
    static let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    static let directory = applicationSupport.appendingPathComponent("vsux", isDirectory: true)

    /// Run before any shared preferences, workspace sessions or command libraries load.
    static func prepare() throws {
        try migrateDirectory(in: applicationSupport)
        migratePreferences()
    }

    /// Publish the complete copy together so commands retain their workspace IDs.
    /// Keep the legacy directory intact for backups and older app versions.
    static func migrateDirectory(in support: URL) throws {
        let manager = FileManager.default
        let destination = support.appendingPathComponent("vsux", isDirectory: true)
        let legacy = support.appendingPathComponent("CmuxLocal", isDirectory: true)
        if try directoryExists(at: destination) { return }
        guard try directoryExists(at: legacy) else { return }

        let staging = support.appendingPathComponent(".vsux-migration-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: legacy, to: staging)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        try manager.moveItem(at: staging, to: destination)
    }

    static func migratePreferences(defaults: UserDefaults = .standard,
                                   legacyDomain: String = "local.cmuxclone.app",
                                   destinationDomain: String = bundleIdentifier) {
        let marker = "vsuxLegacyPreferencesMigrated"
        var current = defaults.persistentDomain(forName: destinationDomain) ?? [:]
        guard current[marker] as? Bool != true else { return }
        for (key, value) in defaults.persistentDomain(forName: legacyDomain) ?? [:] where current[key] == nil {
            current[key] = value
        }
        current[marker] = true
        defaults.setPersistentDomain(current, forName: destinationDomain)
    }

    private static func directoryExists(at url: URL) throws -> Bool {
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }
}
