import Foundation

@main
struct UploadVisualStateTests {
    static func main() throws {
        let time = Date().timeIntervalSince1970 * 1000
        var reducer = GSUploadVisualReducer()
        var rows: [[String: Any]] = (0..<12).map { index in
            ["id": String(repeating: String(index % 10), count: 32), "name": String(repeating: "很长的原始视频😀", count: 40), "uploaded": Int64(5_000_000_000), "total": Int64(10_000_000_000), "measurement": "sent", "state": "uploading", "speed": Int64(999_999_999)]
        }
        // IDs must stay unique even for a fixture with twelve lanes.
        for index in rows.indices { rows[index]["id"] = String(format: "%032d", index) }
        let first = reducer.update(["uploads": rows, "sampledAt": time])
        precondition(first.files.count == 12 && first.files.allSatisfy { $0.percent == 50 && $0.name.utf8.count <= 42 })
        precondition(first.speed == 12 * 999_999_999)
        var second = reducer.update(["uploads": rows, "sampledAt": time + 2000])
        precondition(second.movement == first.movement, "An idle poll animated upload progress")
        rows[0]["uploaded"] = Int64(6_000_000_000)
        second = reducer.update(["uploads": rows, "sampledAt": time + 4000])
        precondition(second.movement == first.movement + 1 && second.files[0].percent == 60)
        rows[0]["uploaded"] = Int64(0)
        rows[0]["speed"] = nil
        let retry = reducer.update(["uploads": rows, "sampledAt": time + 6000])
        precondition(retry.files[0].percent == 0 && retry.files[0].speed == nil)
        rows[0]["total"] = 0
        let unknown = reducer.update(["uploads": rows, "sampledAt": time + 8000])
        precondition(unknown.files[0].fraction == nil && unknown.files[0].percent == nil)
        for i in 5..<40 { _ = reducer.update(["uploads": rows, "sampledAt": time + Double(i * 2000)]) }
        precondition(reducer.state.history.count == 16)
        let encoded = try JSONEncoder().encode(reducer.state)
        precondition(encoded.count < 3800, "All active files exceeded the ActivityKit payload budget")
        print("PASS all 12 files, measured rates, retry resets, unknown size, no idle movement, bounded history; payload \(encoded.count) bytes")
    }
}
