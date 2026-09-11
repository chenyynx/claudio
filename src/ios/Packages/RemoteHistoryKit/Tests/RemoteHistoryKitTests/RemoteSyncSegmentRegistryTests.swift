import XCTest
@testable import RemoteHistoryKit

/// RemoteSyncSegmentRegistry 的行为锁定（[Fix v1.14.30] 段首见次序）。
///
/// bridge 段是随机 8 位十六进制，段的新旧无法从 id 推出；多段并存时排序
/// 需要"本地首次见到该段"的次序。本文件锁死：**按调用方给的先后分配 rank**
/// （不排序——字典序没有时间含义，M2 对抗审查实锤）、已登记段不改 rank
/// （否则历史顺序会随同步抖动）、按会话隔离。
final class RemoteSyncSegmentRegistryTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RemoteSyncSegmentRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_ranks_followsCallerOrderNotLexicographic() {
        // 调用方给的先后 = 段在本地 DB 首次出现的先后（时间序）。
        // "bbbb" 先于 "aaaa" —— 字典序会把它们颠倒（M2 缺陷）。
        let table = RemoteSyncSegmentRegistry.ranks(
            sessionId: "s1", segmentsInFirstSeenOrder: ["bbbb", "aaaa"], defaults: defaults
        )
        XCTAssertEqual(table, ["bbbb": 0, "aaaa": 1],
                       "rank 必须按调用方给的先后分配，不得按字典序重排")
    }

    func test_ranks_keepsExistingRankAndAppendsNew() {
        _ = RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: ["aaaa", "bbbb"], defaults: defaults)
        let table = RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: ["bbbb", "cccc"], defaults: defaults)
        XCTAssertEqual(table["aaaa"], 0, "已登记段永不改 rank")
        XCTAssertEqual(table["bbbb"], 1)
        XCTAssertEqual(table["cccc"], 2, "新段接在最大 rank 之后")
    }

    func test_ranks_idempotentForSameSet() {
        let first = RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: ["aaaa"], defaults: defaults)
        let second = RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: ["aaaa"], defaults: defaults)
        XCTAssertEqual(first, second)
    }

    func test_ranks_dedupesRepeatedInputWithoutDoubleAssigning() {
        let table = RemoteSyncSegmentRegistry.ranks(
            sessionId: "s1", segmentsInFirstSeenOrder: ["aaaa", "aaaa", "bbbb"], defaults: defaults
        )
        XCTAssertEqual(table, ["aaaa": 0, "bbbb": 1],
                       "同一段重复出现在入参里只登记一次（调用方按首见过滤，这里兜底）")
    }

    func test_ranks_ignoresEmptySegmentsAndEmptyInput() {
        XCTAssertEqual(RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: [], defaults: defaults), [:])
        XCTAssertEqual(RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: [""], defaults: defaults), [:],
                       "空段不入表（解析失败的兜底形态）")
    }

    func test_ranks_isolatedPerSession() {
        _ = RemoteSyncSegmentRegistry.ranks(sessionId: "s1", segmentsInFirstSeenOrder: ["aaaa"], defaults: defaults)
        let other = RemoteSyncSegmentRegistry.ranks(sessionId: "s2", segmentsInFirstSeenOrder: ["bbbb"], defaults: defaults)
        XCTAssertEqual(other, ["bbbb": 0], "不同本地会话各自一张表")
        XCTAssertEqual(RemoteSyncSegmentRegistry.currentRanks(sessionId: "s1", defaults: defaults), ["aaaa": 0])
    }

    func test_currentRanks_readOnlyDoesNotCreateEntry() {
        _ = RemoteSyncSegmentRegistry.currentRanks(sessionId: "s3", defaults: defaults)
        XCTAssertEqual(RemoteSyncSegmentRegistry.currentRanks(sessionId: "s3", defaults: defaults), [:])
    }
}
