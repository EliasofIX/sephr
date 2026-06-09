import XCTest
@testable import SephrKit

final class TabEventBusTests: XCTestCase {
    func testPerTabSubscriberReceivesOnlyItsTabsEvents() {
        let bus = TabEventBus()
        let tabA = UUID(), tabB = UUID()
        var received: [TabEvent] = []
        let token = bus.subscribe(tabID: tabA) { received.append($0) }
        bus.post(TabEvent(tabID: tabA, kind: .title))
        bus.post(TabEvent(tabID: tabB, kind: .title))
        bus.post(TabEvent(tabID: tabA, kind: .url))
        XCTAssertEqual(received.map(\.kind), [.title, .url])
        _ = token
    }

    func testStructureSubscriberReceivesStructureEvents() {
        let bus = TabEventBus()
        var count = 0
        let token = bus.subscribeStructure { count += 1 }
        bus.postStructure()
        bus.postStructure()
        XCTAssertEqual(count, 2)
        _ = token
    }

    func testTokenDeallocUnsubscribes() {
        let bus = TabEventBus()
        let tab = UUID()
        var count = 0
        var token: TabEventToken? = bus.subscribe(tabID: tab) { _ in count += 1 }
        bus.post(TabEvent(tabID: tab, kind: .favicon))
        token = nil
        bus.post(TabEvent(tabID: tab, kind: .favicon))
        XCTAssertEqual(count, 1)
        _ = token
    }
}
