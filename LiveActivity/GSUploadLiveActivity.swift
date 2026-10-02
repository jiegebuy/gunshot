import Foundation
import ActivityKit

// Loaded by the injected host only when the companion framework and extension
// are installed. The data model is in this same module in host and extension.
@MainActor @objc(GSUploadLiveActivity)
public final class GSUploadLiveActivity: NSObject {
    private static var activity: Activity<GSUploadAttributes>?
    private static var reducer = GSUploadVisualReducer()
    private static var pending: ActivityContent<GSUploadVisualState>?
    private static var writer: Task<Void, Never>?
    private static var generation = 0
    private static var result = "idle"

    @objc(startWithIdentifier:language:)
    public static func start(identifier: String, language: String) {
        finish(success: false)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { result = "disabled"; return }
        reducer = GSUploadVisualReducer()
        let previous = Activity<GSUploadAttributes>.activities
        do {
            activity = try Activity.request(attributes: GSUploadAttributes(batchID: identifier, language: language), content: ActivityContent(state: reducer.state, staleDate: Date().addingTimeInterval(10)), pushType: nil)
            result = "running"
        } catch { result = "request_failed" }
        Task { for old in previous { await old.end(nil, dismissalPolicy: .immediate) } }
    }

    @objc(updateWithPayload:)
    public static func update(payload: [String: Any]) {
        let state = reducer.update(payload)
        enqueue(state, staleDate: state.observedAt.addingTimeInterval(10))
    }

    private static func enqueue(_ state: GSUploadVisualState, staleDate: Date) {
        guard let current = activity else { return }
        // Never silently drop active files to fit the ActivityKit payload.
        guard let encoded = try? JSONEncoder().encode(state), encoded.count < 3800 else { result = "payload_too_large"; return }
        pending = ActivityContent(state: state, staleDate: staleDate, relevanceScore: 100)
        guard writer == nil else { return }
        let epoch = generation
        writer = Task {
            while generation == epoch, activity?.id == current.id, let next = pending {
                pending = nil
                await current.update(next)
            }
            if generation == epoch { writer = nil }
        }
    }

    @objc(markUnavailable)
    public static func markUnavailable() {
        var state = reducer.state; state.status = 3; state.speed = nil
        enqueue(state, staleDate: Date())
    }

    @objc(finishWithSuccess:)
    public static func finish(success: Bool) {
        generation += 1
        let current = activity, oldWriter = writer
        var state = reducer.state; state.status = success ? 1 : 2; state.speed = 0
        activity = nil; pending = nil; writer = nil
        result = success ? "finished" : "stopped"
        guard let current else { return }
        Task {
            await oldWriter?.value
            await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    @objc(snapshot)
    public static func snapshot() -> [String: Any] { ["status": result, "active": activity != nil] }
}
