import Foundation

/// Per-tab change kinds. `structure` (add/remove/reorder) has its own
/// channel — see `subscribeStructure`.
public struct TabEvent {
    public enum Kind: Equatable { case title, favicon, active, url, loading }
    public let tabID: UUID
    public let kind: Kind
    public init(tabID: UUID, kind: Kind) {
        self.tabID = tabID
        self.kind = kind
    }
}

/// Keep the token alive for the lifetime of the subscription;
/// dropping it unsubscribes.
public final class TabEventToken {
    fileprivate let id = UUID()
    fileprivate weak var bus: TabEventBus?
    fileprivate let tabID: UUID?   // nil = structure subscription
    fileprivate init(bus: TabEventBus, tabID: UUID?) {
        self.bus = bus
        self.tabID = tabID
    }
    deinit { bus?.unsubscribe(token: self) }
}

/// Main-thread-only fine-grained tab event bus. Replaces the global
/// `.sephrTabModelChanged` broadcast: cells subscribe to their own tab,
/// the sidebar subscribes to structure only.
public final class TabEventBus {
    public static let shared = TabEventBus()
    private var perTab: [UUID: [(UUID, (TabEvent) -> Void)]] = [:]
    private var structure: [(UUID, () -> Void)] = []
    public init() {}

    public func subscribe(tabID: UUID,
                          handler: @escaping (TabEvent) -> Void) -> TabEventToken {
        let token = TabEventToken(bus: self, tabID: tabID)
        perTab[tabID, default: []].append((token.id, handler))
        return token
    }

    public func subscribeStructure(handler: @escaping () -> Void) -> TabEventToken {
        let token = TabEventToken(bus: self, tabID: nil)
        structure.append((token.id, handler))
        return token
    }

    public func post(_ event: TabEvent) {
        perTab[event.tabID]?.forEach { $0.1(event) }
    }

    public func postStructure() {
        structure.forEach { $0.1() }
    }

    fileprivate func unsubscribe(token: TabEventToken) {
        if let tabID = token.tabID {
            perTab[tabID]?.removeAll { $0.0 == token.id }
            if perTab[tabID]?.isEmpty == true { perTab[tabID] = nil }
        } else {
            structure.removeAll { $0.0 == token.id }
        }
    }
}
