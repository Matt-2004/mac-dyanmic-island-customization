import Foundation

/// Priority of a temporary peek. Higher wins; a lower peek waits in the queue.
/// Order: notification > critical (10%) battery > AirPods > other power events.
enum PeekKind: Int, Comparable {
    case power = 1
    case airpods = 2
    case criticalPower = 3
    case notification = 4

    static func < (lhs: PeekKind, rhs: PeekKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PeekContent: Equatable {
    case notification(IslandNotification)
    /// `isLive` peeks follow PowerService updates (e.g. time to full appears a moment after plugging in);
    /// debug peeks keep their sample snapshot.
    case power(event: PowerEvent, snapshot: PowerSnapshot, isLive: Bool)
    case airpods(AirPodsPeekInfo)
}

struct PeekItem: Identifiable, Equatable {
    let id: UUID
    var content: PeekContent
    let kind: PeekKind
    let duration: TimeInterval
    let createdAt: Date

    init(content: PeekContent, kind: PeekKind, duration: TimeInterval, createdAt: Date = Date()) {
        id = UUID()
        self.content = content
        self.kind = kind
        self.duration = duration
        self.createdAt = createdAt
    }

    /// The island state that displays this peek.
    var islandState: IslandState {
        switch content {
        case .notification: return .peek
        case .power: return .powerPeek
        case .airpods: return .airpodsPeek
        }
    }
}
