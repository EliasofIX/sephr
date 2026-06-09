import Dispatch
import Foundation

/// Per-tab change kinds. `structure` (add/remove/reorder) has its own
/// channel — see `subscribeStructure`.
public struct TabEvent: Equatable {
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
    private var perTab: [UUID: [(id: UUID, handler: (TabEvent) -> Void)]] = [:]
    private var structure: [(id: UUID, handler: () -> Void)] = []

    /// Independent instances are supported, primarily for tests.
    public init() {}

    /// The bus retains `handler` until the token is released; capture `self`
    /// weakly in the handler, or the token (typically stored on `self`) will
    /// never deallocate.
    public func subscribe(tabID: UUID,
                          handler: @escaping (TabEvent) -> Void) -> TabEventToken {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = TabEventToken(bus: self, tabID: tabID)
        perTab[tabID, default: []].append((token.id, handler))
        return token
    }

    /// The bus retains `handler` until the token is released; capture `self`
    /// weakly in the handler, or the token (typically stored on `self`) will
    /// never deallocate.
    public func subscribeStructure(handler: @escaping () -> Void) -> TabEventToken {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = TabEventToken(bus: self, tabID: nil)
        structure.append((token.id, handler))
        return token
    }

    public func post(_ event: TabEvent) {
        dispatchPrecondition(condition: .onQueue(.main))
        let handlers = perTab[event.tabID] ?? []   // snapshot: handlers added during
        handlers.forEach { $0.handler(event) }     // post don't see this event; removed
    }                                              // ones still receive it

    public func postStructure() {
        dispatchPrecondition(condition: .onQueue(.main))
        let handlers = structure                   // snapshot (see post)
        handlers.forEach { $0.handler() }
    }

    fileprivate func unsubscribe(token: TabEventToken) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let tabID = token.tabID {
            perTab[tabID]?.removeAll { $0.id == token.id }
            if perTab[tabID]?.isEmpty == true { perTab[tabID] = nil }
        } else {
            structure.removeAll { $0.id == token.id }
        }
    }
}
