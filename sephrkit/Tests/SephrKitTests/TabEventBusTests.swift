import XCTest
import SephrKit

final class TabEventBusTests: XCTestCase {
    func testPerTabSubscriberReceivesOnlyItsTabsEvents() {
        let bus = TabEventBus()
        let tabA = UUID(), tabB = UUID()
        var received: [TabEvent] = []
        let token = bus.subscribe(tabID: tabA) { received.append($0) }
        withExtendedLifetime(token) {
            bus.post(TabEvent(tabID: tabA, kind: .title))
            bus.post(TabEvent(tabID: tabB, kind: .title))
            bus.post(TabEvent(tabID: tabA, kind: .url))
            XCTAssertEqual(received.map(\.kind), [.title, .url])
        }
    }

    func testTwoSubscribersOnSameTabBothReceivePost() {
        let bus = TabEventBus()
        let tab = UUID()
        var countA = 0, countB = 0
        let tokenA = bus.subscribe(tabID: tab) { _ in countA += 1 }
        let tokenB = bus.subscribe(tabID: tab) { _ in countB += 1 }
        withExtendedLifetime((tokenA, tokenB)) {
            bus.post(TabEvent(tabID: tab, kind: .title))
            XCTAssertEqual(countA, 1)
            XCTAssertEqual(countB, 1)
        }
    }

    func testStructureSubscriberReceivesStructureEvents() {
        let bus = TabEventBus()
        var count = 0
        let token = bus.subscribeStructure { count += 1 }
        withExtendedLifetime(token) {
            bus.postStructure()
            bus.postStructure()
            XCTAssertEqual(count, 2)
        }
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
    }

    func testStructureTokenDeallocUnsubscribes() {
        let bus = TabEventBus()
        var count = 0
        var token: TabEventToken? = bus.subscribeStructure { count += 1 }
        bus.postStructure()
        token = nil
        bus.postStructure()
        XCTAssertEqual(count, 1)
    }

    func testHandlerCanResubscribeDuringPost() {
        let bus = TabEventBus()
        let tab = UUID()
        var count = 0
        var token: TabEventToken?
        func resubscribe() {
            token = bus.subscribe(tabID: tab) { _ in
                count += 1
                token = nil
                resubscribe()
            }
        }
        resubscribe()
        bus.post(TabEvent(tabID: tab, kind: .title))
        XCTAssertEqual(count, 1)
        bus.post(TabEvent(tabID: tab, kind: .title))
        XCTAssertEqual(count, 2)
        token = nil
    }
}
