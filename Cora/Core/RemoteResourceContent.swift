import Foundation

struct RemoteResourceContent: Identifiable, Sendable {
    let id: String
    let resourceName: String
    let subscriptionName: String
    let kind: RemoteResource.Kind
    let sourceURL: String
    let content: String
    let size: Int64
    let updatedAt: Date?
    let isTruncated: Bool
}

enum RemoteResourceContentResult: Sendable {
    case content(RemoteResourceContent)
    case unavailable(String)
}
