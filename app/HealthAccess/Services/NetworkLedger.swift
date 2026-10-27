import Foundation
import Observation

/// "What left this phone": every outgoing network call this app makes, by host and event name, for the current session.
/// Health Access has no server of its own; the only entries ever recorded are the opt-in usage statistics.
@MainActor
@Observable
final class NetworkLedger {
    static let shared = NetworkLedger()

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let at: Date
        let host: String
        let event: String
    }

    private(set) var entries: [Entry] = []

    private init() {}

    func record(host: String, event: String) {
        entries.append(Entry(at: Date(), host: host, event: event))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
}
