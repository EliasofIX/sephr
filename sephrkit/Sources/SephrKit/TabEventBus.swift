import Dispatch
import Foundation

/// Per-tab change kinds. `structure` (add/remove/reorder) has its own
/// channel — see `subscribeStructure`.
public struct TabEvent: Equatable {
    public enum Kind: Equatable { case title, favicon, active, url, loading, audio, media }
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

/// Marker for non-tab-scoped subscriptions on `TabEventBus`. Distinct UUID
/// per channel so unsubscribe routes to the right list without an extra
/// kind enum on the token.
private let kStructureChannel = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let kActiveChannel    = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

/// Main-thread-only fine-grained tab event bus. Replaces the global
/// `.sephrTabModelChanged` broadcast: cells subscribe to their own tab,
/// the sidebar subscribes to structure only, the window controller
/// subscribes to active-tab changes.
public final class TabEventBus {
    public static let shared = TabEventBus()
    private var perTab: [UUID: [(id: UUID, handler: (TabEvent) -> Void)]] = [:]
    private var structure: [(id: UUID, handler: () -> Void)] = []
    /// Fires on every active-tab swap. Lighter than the structure channel
    /// — sidebar/favorites/now-playing-pill don't care about which tab is
    /// active, only the window controller (and URL field's re-anchor)
    /// does. Splitting it out means a Cmd+1 keypress doesn't wake five
    /// structure subscribers.
    private var active: [(id: UUID, handler: () -> Void)] = []

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
        let token = TabEventToken(bus: self, tabID: kStructureChannel)
        structure.append((token.id, handler))
        return token
    }

    /// Fires whenever the active tab changes (any path: sidebar click, key
    /// shortcut, external link route, popup adoption, close-promotes).
    /// Same retention rules as the other channels.
    public func subscribeActiveChange(handler: @escaping () -> Void) -> TabEventToken {
        dispatchPrecondition(condition: .onQueue(.main))
        let token = TabEventToken(bus: self, tabID: kActiveChannel)
        active.append((token.id, handler))
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

    public func postActiveChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        let handlers = active                      // snapshot (see post)
        handlers.forEach { $0.handler() }
    }

    fileprivate func unsubscribe(token: TabEventToken) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch token.tabID {
        case kStructureChannel:
            structure.removeAll { $0.id == token.id }
        case kActiveChannel:
            active.removeAll { $0.id == token.id }
        case let tabID?:
            perTab[tabID]?.removeAll { $0.id == token.id }
            if perTab[tabID]?.isEmpty == true { perTab[tabID] = nil }
        case nil:
            break
        }
    }
}
