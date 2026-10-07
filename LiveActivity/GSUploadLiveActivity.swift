import Foundation
import ActivityKit
import UIKit
import OSLog

// Loaded by the injected host only when the companion framework and extension
// are installed. The data model is in this same module in host and extension.
@MainActor @objc(GSUploadLiveActivity)
@available(iOSApplicationExtension, unavailable)
public final class GSUploadLiveActivity: NSObject {
    private static var activity: Activity<GSUploadAttributes>?
    private static var reducer = GSUploadVisualReducer()
    private static var pending: ActivityContent<GSUploadVisualState>?
    private static var writer: Task<Void, Never>?
    private static var generation = 0
    private static var result = "idle"
    private static var batch: GSUploadAttributes?
    private static var stateObserver: Task<Void, Never>?
    private static var foregroundObserver: NSObjectProtocol?
    private static var lastRequestUptime: TimeInterval?
    private static var requestError: String?
    private static var recoveries = 0
    private static let logger = Logger(subsystem: "com.google.photos.gotohp.activity", category: "lifecycle")

    @objc(startWithIdentifier:language:)
    public static func start(identifier: String, language: String) {
        finish(success: false)
        reducer = GSUploadVisualReducer()
        batch = GSUploadAttributes(batchID: identifier, language: language)
        recoveries = 0; lastRequestUptime = nil
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in restoreIfNeeded() }
            }
        }
        let previous = Activity<GSUploadAttributes>.activities
        requestActivity(recovering: false)
        Task { for old in previous { await old.end(nil, dismissalPolicy: .immediate) } }
    }

    private static func requestActivity(recovering: Bool) {
        guard let attributes = batch else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { result = "disabled"; return }
        guard UIApplication.shared.applicationState == .active else { result = "waiting_foreground"; return }
        // Failed requests and daemon reconciliation must not create a request loop.
        let now = ProcessInfo.processInfo.systemUptime
        guard lastRequestUptime.map({ now - $0 >= 5 }) ?? true else { return }
        lastRequestUptime = now; requestError = nil
        do {
            let current = try Activity.request(attributes: attributes, content: ActivityContent(state: reducer.state, staleDate: reducer.state.observedAt.addingTimeInterval(10)), pushType: nil)
            activity = current
            result = "running"
            if recovering { recoveries += 1 }
            let epoch = generation
            stateObserver = Task {
                for await state in current.activityStateUpdates {
                    guard epoch == generation, activity?.id == current.id else { return }
                    if state == .ended || state == .dismissed {
                        invalidateCurrent(state == .dismissed ? "dismissed" : "ended")
                        return
                    }
                }
            }
            logger.info("Upload activity created; recovery=\(recovering, privacy: .public)")
        } catch {
            let error = error as NSError
            requestError = "\(error.domain):\(error.code)"
            result = "request_failed"
            logger.error("Upload activity request failed: \(requestError ?? "unknown", privacy: .public)")
        }
    }

    private static func invalidateCurrent(_ reason: String) {
        generation += 1
        activity = nil; pending = nil; writer?.cancel(); writer = nil
        stateObserver?.cancel(); stateObserver = nil
        result = reason
        logger.notice("Upload activity unavailable: \(reason, privacy: .public)")
    }

    private static func reconcile() {
        guard let current = activity else { return }
        if current.activityState == .dismissed { invalidateCurrent("dismissed"); return }
        if current.activityState == .ended { invalidateCurrent("ended"); return }
        // A surviving local Activity object is not proof the daemon still owns
        // it (e.g. after daemon restart). Allow initial registration to settle.
        if let lastRequestUptime, ProcessInfo.processInfo.systemUptime - lastRequestUptime >= 5,
           !Activity<GSUploadAttributes>.activities.contains(where: { $0.id == current.id }) {
            invalidateCurrent("missing")
        }
    }

    private static func restoreIfNeeded() {
        guard batch != nil else { return }
        reconcile()
        // Terminal activities may already report dismissed when the ended
        // event arrives. Restore only after the user is back in this app;
        // never replace a dismissed card while the app is in the background.
        if activity == nil { requestActivity(recovering: true) }
    }

    @objc(updateWithPayload:)
    public static func update(payload: [String: Any]) {
        let state = reducer.update(payload)
        restoreIfNeeded()
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
            while !Task.isCancelled, generation == epoch, activity?.id == current.id, let next = pending {
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
        batch = nil
        stateObserver?.cancel(); stateObserver = nil
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
    public static func snapshot() -> [String: Any] {
        reconcile()
        var snapshot: [String: Any] = ["status": result, "active": activity != nil,
            "allowed": ActivityAuthorizationInfo().areActivitiesEnabled, "recoveries": recoveries,
            "fileCount": reducer.state.files.count, "batchActive": batch != nil]
        if let requestError { snapshot["requestError"] = requestError }
        return snapshot
    }
}
