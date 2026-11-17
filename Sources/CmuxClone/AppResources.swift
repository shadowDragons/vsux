import Foundation

/// SwiftPM's generated lookup differs between the native and Xcode drivers.
/// Installed apps always keep their copied bundle under Contents/Resources.
enum AppResources {
    static let bundle = packagedBundle(in: Bundle.main.resourceURL) ?? Bundle.module

    static func packagedBundle(in resourceDirectory: URL?) -> Bundle? {
        resourceDirectory
            .map { $0.appendingPathComponent("CmuxClone_CmuxClone.bundle") }
            .flatMap(Bundle.init(url:))
    }
}
