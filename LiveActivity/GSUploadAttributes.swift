import ActivityKit

public struct GSUploadAttributes: ActivityAttributes {
    public typealias ContentState = GSUploadVisualState
    public var batchID: String
    public var language: String
    public init(batchID: String, language: String) { self.batchID = batchID; self.language = language }
}
