import Foundation

@objc(GSPhotoKitTaskContext)
final class GSPhotoKitTaskContext: NSObject {
    @TaskLocal static var cachePath: String?

    @objc(currentCachePath)
    static func currentCachePath() -> String? { cachePath }

    @objc(performWithCachePath:operation:)
    static func perform(cachePath: String, operation: () -> Void) {
        $cachePath.withValue(cachePath, operation: operation)
    }
}
