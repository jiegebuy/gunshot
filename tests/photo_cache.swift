import Foundation

@main
struct PhotoCacheTest {
    static func createFile(_ cache: GSPhotoKitCache, value: UInt8) async -> URL {
        await withCheckedContinuation { continuation in
            precondition(cache.perform {
                Task {
                    // This hop exercises propagation to an asynchronously scheduled task.
                    await Task.yield()
                    let url = try! FileManager.default.url(for: .itemReplacementDirectory,
                        in: .userDomainMask, appropriateFor: cache.directory, create: true)
                    precondition(url.path.hasPrefix(cache.directory.path + "/"))
                    try! Data(repeating: value, count: 1024).write(to: url.appendingPathComponent("fixture"))
                    continuation.resume(returning: url)
                }
            })
        }
    }
    static func main() async throws {
        let a = try GSPhotoKitCache.create()
        let b = try GSPhotoKitCache.create()
        async let first = createFile(a, value: 11)
        async let second = createFile(b, value: 22)
        let (one, two) = await (first, second)
        precondition(one != two)
        precondition(GSPhotoKitTaskContext.currentCachePath() == nil)
        let unrelated = try FileManager.default.url(for: .itemReplacementDirectory,
            in: .userDomainMask, appropriateFor: a.directory, create: true)
        precondition(!unrelated.path.hasPrefix(a.directory.path))
        try a.remove()
        precondition(!FileManager.default.fileExists(atPath: one.path))
        precondition(FileManager.default.fileExists(atPath: two.path))
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
        precondition(!a.perform { fatalError("revoked lease was used") })
        try b.remove()
        try FileManager.default.removeItem(at: unrelated)
        print("PhotoKit task-local cache isolation passed")
    }
}
