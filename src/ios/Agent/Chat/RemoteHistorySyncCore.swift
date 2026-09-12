// RemoteHistorySyncCore — 远端会话恢复的校准计划纯函数（官方 replaceEntries 语义）。
//
// 背景（2026-09-10，v1.14.18）：此前的恢复链路依赖三套自创机制——
// RemoteSessionMetadata 水位、contentFingerprint 指纹、BackfillCore 增量判定。
// live 落库 id（UUID）与 bridge 回放 id（bridge-{seq}）是两套永不相交的标识
// 系统，水位只抬最终轮、tool_result 回放无 seq、指纹 prefix(3) 有盲区——
// 四个盲区叠加 = 杀后台重进乱序/重复/吞（见 Bug 经验库 Claudio 条目）。
//
// 本模块对齐官方（ccpocket get_history + replaceEntries，websocket.ts:3139）：
// bridge history 是唯一真相。给定 bridge history 转换出的 RawMessage 序列和
// 本地 DB 现有行，算出"校准计划"——保留什么、删除什么、插入什么。
//
// 保留规则：
// - user 行全保留（live 落库的用户消息，含附件 mediaRef、XML 解析结果等
//   本地增强；bridge 端 user_input 的图片等价信息少于本地行，换血反而丢数据）
//   ↳ 防双份（排查 2026-09-10）：bridge 回放的 user_input（bridge-{seq}）与
//     live 落库的同文本 user 行（UUID）并存 = 同一条用户消息渲染两次且
//     位置错乱（UUID 行按旧 sort_order 进保留区，回放行按 history 序）。
//     修法在 inserts 端：history 的 user 行若已有同文本本地行 → 不插入
//     （本地行保住图片+解析，bridge 行不重复落库；该 seq 每轮校准重复
//     判定一次 skip，幂等无膨胀）。
// - 非 user 行分两类：
//   · UUID 行（live 落库，id 非 "bridge-" 前缀）→ 删除，其内容已由
//     bridge-{seq} 行承载（同内容换血）
//   · bridge-{seq} 行 → 只增不删。⚠️ bridge 端 MAX_HISTORY_PER_SESSION=100
//     （session.ts:186 trimHistory），get_history 只返回尾部 100 条——
//     更早的 bridge-{seq} 行不在本次 history 集里，若按"不在集即删"的
//     教条 replaceEntries 处理，长会话的 assistant/tool_result 历史会被
//     永久吞掉（对抗审查 R1 实锤）。bridge 是增量的真相，本地是累积缓存。
//
// 纯函数：无 actor / DB / UI 依赖，可单测（RemoteHistoryBackfillTests）。

import Foundation

/// 一次校准的执行计划。由 `ChatStore.replaceRemoteHistory` 在单事务内执行。
struct RemoteHistoryReplacePlan {
    /// 需要插入的行（按 bridge history 顺序；sortOrder 由事务内显式赋值）
    let inserts: [RawMessage]
    /// 需要删除的 DB 行 id（live UUID 行 + 不在 history 集内的多余行）
    let deleteIds: [String]
    /// 保留的原行数（诊断用）
    let keptCount: Int
    /// 最终排序的 id 序列（bridge history 序，防双份被挡的回放 user 行位置
    /// 替换为承载同内容的本地行 id）。replaceRemoteHistory 用它 renumber
    /// sort_order——没有它，本地 user 行（UUID）不在 history 序列内，
    /// renumber 的"retained 排前"规则会把所有 user 行顶到最前 = 顺序大乱
    /// （pp 真机实锤 2026-09-10 07:06 日志：两个 user 气泡置顶、回复全在后）。
    let unifiedFinalOrderIds: [String]

    var isEmpty: Bool { inserts.isEmpty && deleteIds.isEmpty }
}

enum RemoteHistorySyncCore {

    /// 计算校准计划。
    ///
    /// - Parameters:
    ///   - historyRaws: bridge history 转换出的行（管线已 buildRaw，
    ///     assistant/tool_result 行 id = `bridge-{seq}`）
    ///   - dbRows: 本地 DB 现有行（`ChatStore.loadMessages` 原样输出，按
    ///     sort_order 升序）
    ///   - nonEngineSeqs: bridge history 中存在但**不转换**为 engine 消息的
    ///     seq 集合（result/status 等类型）。落在这些 seq 上的 DB 行必然是
    ///     错绑残留（live 曾把 result 的 seq 错注入 assistant 行）→ 删。
    ///     仅此集合内的 bridge 行可删——trim 窗口外的老行（seq 不在本次
    ///     history）依旧只增不删（R1 规则）。
    ///   - evictPastRows: [Fix 2026-09-11] past id 空间迁移模式。bridge 端
    ///     disk 解析补全 tool_result/thinking 后，past-{index} 序列重排
    ///     （同一会话 index 全变），旧残缺序列的 past 行与新序列同 id 不同
    ///     内容——id 命中 keep 会保留旧残缺行（修复失效）。CLIENT 在检测到
    ///     迁移未完成 + 全量 fetch 成功时传 true：本次全部 past 行进
    ///     deleteIds，同事务按新序列重插。日常路径恒 false（past 行只增不删）。
    static func planReplace(historyRaws: [RawMessage], dbRows: [RawMessage], nonEngineSeqs: Set<Int> = [], forceFullReshuffle: Bool = false, evictPastRows: Bool = false, currentSegment: String? = nil, previousSegment: String? = nil, previousSegments: Set<String> = [], supersededInputIds: Set<String> = []) -> RemoteHistoryReplacePlan {
        let dbIds = Set(dbRows.map { $0.id })

        // 删除③（seq 空间重置检测，优先级最高）：bridge-{seq} 的 seq 是
        // **per-bridge-session** 计数——resume/重启会 spawn 新 bridge 会话
        // （官方语义，注释见 CCPocketClient.reconnectNow），新会话从 seq=1
        // 重新计数。此时 DB 里旧空间的 bridge-1..N 与新空间的 bridge-1..M
        // 同 id 不同内容 → id 命中 keep 旧行 = 内容串台/重复渲染（pp 真机
        // 实锤：正文/卡片/思考块全部双份）。信号（确定性优先）：
        // · forceFullReshuffle = bridgeId 与上次同步不同（per-chat 存储）
        // · 兜底：DB bridge max seq > history max seq（短会话会漏——
        //   旧 3 行 vs 新 5 行不触发，真实翻车后补 bridgeId 主信号）
        // 重置 → 非 user 行全部换血到新空间（user 行 UUID 无前缀，
        // 由防双份两键挡回放重复）。
        // [Fix v1.14.29] 统一走 ReplayRowId：兼容 `bridge-{seq}`（旧）与
        // `bridge-{ns}-{seq}`（新；ns = 本地会话前 8 位，见 ReplayRowId）。
        func bridgeSeq(_ id: String) -> Int? { ReplayRowId.parseBridgeSeq(id) }
        // [Fix v1.14.30 / 对抗审查 A2] **段作用域**：seq 只在同一个 bridge
        // 会话（段）内单调。多段并存时（换过 bridge 会话；或同一 chat 被
        // iCloud 同步到另一台设备，各自持不同 bridge 会话）按 seq 直接比较
        // 就是跨段误判——会删掉别的设备/旧段的行，且删除会对端同步 → 对端
        // 校准又插回 → "删/回插乒乓"。
        //
        // 判据只对本设备**自己的段**生效；外来段的行任何删除规则都不碰：
        //   自己的段 = ①无段（更早形态，待迁移补段）②本次 fetch 的段
        //              ③上一个 bridge 会话的段（换会话瞬间的旧空间，已被
        //                本次全量覆盖 = 换血靶子）
        //              ④DB 段集反查出的旧段（stored 失明：iCloud 恢复带回
        //                他机/旧会话桥行而 UserDefaults 无记录——全量路径专属，
        //                Backfill §4.5 传入；delta 路径传空集）
        func segmentOf(_ id: String) -> String? { ReplayRowId.parseSegment(id) }
        func isOwnSegment(_ row: RawMessage) -> Bool {
            guard let seg = segmentOf(row.id) else { return true }
            if let currentSegment, seg == currentSegment { return true }
            if let previousSegment, seg == previousSegment { return true }
            if previousSegments.contains(seg) { return true }
            return false
        }
        let dbBridgeSeqs = dbRows.compactMap { row -> Int? in
            guard row.role != .user, isOwnSegment(row) else { return nil }
            return bridgeSeq(row.id)
        }
        let historySeqs = historyRaws.compactMap { bridgeSeq($0.id) }
        // [对抗审查 A3] 只有"新 history 在**同 seq 也是 user 行**"时才敢删旧
        // 空间的回放 user 行——同 seq 不同角色说明两边不是同一轮对话（换过
        // claude 会话等），删了就真丢内容。
        let historyUserSeqs = Set(
            historyRaws.filter { $0.role == .user }.compactMap { bridgeSeq($0.id) }
        )
        // bridgeId 切换（sync 层传入）是确定性信号；长度启发式只是无
        // bridgeId 时的兜底（短会话 dbMax<=histMax 时漏判——真实翻车）。
        let seqSpaceReset = forceFullReshuffle || {
            if let dbMax = dbBridgeSeqs.max(), let histMax = historySeqs.max() {
                return dbMax > histMax
            }
            return false
        }()

        // 删除①：live 落库的非 user UUID 行（id 非 "bridge-"/"past-" 前缀）。
        // [对抗审查 R4 实锤 2026-09-10] past-{index} 行（C-5.5 磁盘历史回放）
        // 同样无 bridge- 前缀——旧规则会把它们当 live UUID 行删掉且不回插
        // （插入按 keptIds 去重，past 行保留在 keptIds → 命中跳过）→ 磁盘
        // 历史每次校准净丢失。past 行是回放产物，身份稳定（磁盘
        // append-only），必须与 bridge-{seq} 行同享"只增不删"，由 id 集
        // 去重。大一统行退役（v1.14.20）后 live 落库恒为 UUID，删除①的
        // 靶子只有真 UUID 行。
        // 删除②：错绑残留行——id=bridge-{seq} 但该 seq 的 wire 消息是
        //         result/status（不进 engine/historyRaws），此行内容与回放
        //         行重复且永远无法被 id 命中（排查 2026-09-10 实锤）。
        // 删除③：seq 空间重置 → 全部非 user bridge 行换血（见上）。
        // bridge-{seq} 行其余情况只增不删——trim 窗口外的老 seq 不在本次
        // history 集里，删了就是永久吞消息（R1 审查实锤）。
        let deleteIds = dbRows
            .filter { row in
                // [Fix 2026-09-11] past id 空间迁移（见参数注释）：迁移模式
                // 下 past 行全清（user role 的 past 行同样清——它们会被新
                // 序列同事务重插；命中本地 owner 则不插由 unified 序承接）。
                // 检查须先于 user 保留规则。
                if row.id.hasPrefix("past-") { return evictPastRows }
                // [Fix v1.14.30.1 / F3] 被取代的原始输入（编辑重发/删除——
                // bridge 无撤回协议，回放不认领不插入；此规则清掉此前校准已
                // 入库的对应回放行，防"删不掉的双份"）。
                if row.role == .user, let cid = row.clientMessageId, !cid.isEmpty,
                   supersededInputIds.contains(cid) { return true }
                // [对抗审查 A2] 外来段的行：任何删除规则都不碰（跨设备/旧来源
                // 的段，删了就是删别的设备的内容 + 回插乒乓）。
                if !isOwnSegment(row) { return false }
                if row.role == .user {
                    // [对抗审查 A3] 换会话（seq 空间重置）时，旧空间的回放
                    // user 行（无段/旧段）若同 seq 已被本次 history 覆盖 →
                    // 内容由新行或本地承载行承接，删除旧行。不删则它永久
                    // 占住该 seq（keep 命中）→ 新内容永不落库 + 用户发言
                    // 被甩到会话末尾（每次校准复现，幂等不会自愈）。
                    // 未被 history 覆盖的（trim 窗口外）保留——删了不回插
                    // = 净丢内容。
                    guard seqSpaceReset, let seq = bridgeSeq(row.id) else { return false }
                    return segmentOf(row.id) != currentSegment && historyUserSeqs.contains(seq)
                }
                // [对抗审查 R4 追加] past-{index} 行是磁盘历史回放（claude
                // 会话 append-only，序列跨 bridge 会话稳定）——seq 空间重置
                // 换血的靶子是旧 bridge 空间的 bridge-{seq}/UUID 行，past 行
                // 不属于任何 seq 空间，换血时必须保留（删了不回插：dbIds
                // 快照命中插入跳过 → 净删 = 磁盘历史丢失）。
                if seqSpaceReset { return true }
                if !row.id.hasPrefix("bridge-") { return true }
                guard let seq = bridgeSeq(row.id) else { return false }
                return nonEngineSeqs.contains(seq)
            }
            .map { $0.id }

        // 插入：history 中 DB 还没有的行（按 history 原序）。
        // [对抗审查 R4 模拟实锤 2026-09-10] 基准必须用"删除后存活的 id 集"
        // 而非删除前快照——seq 空间重置/bridgeId 切换场景：旧空间 bridge-1
        // 行被删、新空间 bridge-1 行（同 id 不同内容）若按删除前 dbIds 判定
        // 会被跳过 → 换血后内容丢失（test_seqSpaceReset 的期望与之矛盾，
        // 测试步骤挂起从未执行所以一直没暴露）。keptIds = dbIds − deleteIds。
        // [Fix 2026-09-11] deleteIdSet 提前定义：防双份 owner 池必须排除
        // 本轮将删除的行——past 迁移模式下 past user 行会进 deleteIds，若
        // 仍进池会把新序列的同文本行顶替成"旧行 id"（旧行已删 + 新行不插
        // = 用户消息净丢）。
        let deleteIdSet = Set(deleteIds)
        // [Fix v1.14.30] 身份对账交给独立模块 RemoteHistoryOwnerIndex：
        // 优先级 clientMessageId（协议身份）→ toolUseId → 归一化正文队列兜底。
        // 旧实现把这三件事按正文猜着内联在这里，附件消息（本地 parts=[xml,
        // 正文] vs bridge "正文+XML"）、纯图片消息（无正文）、重复文本都会猜错。
        var owners = RemoteHistoryOwnerIndex(dbRows: dbRows, excluding: deleteIdSet)
        let keptIds = dbIds.subtracting(deleteIdSet)
        var inserts: [RawMessage] = []
        var unifiedFinalOrderIds: [String] = []
        // [Fix v1.14.30] 已落库的回放 user 行若认领到本地承载行：由本地行顶替
        // 它的位置，并把这条多余的**回放 user 行**排进删除。否则会出现
        // "回放行占位 + 本地行无人认领 → 落 after 桶甩到会话末尾 + 同一内容
        // 两个气泡"（对抗审查 2026-09-11 构造实证；老 build 对附件消息按原文
        // 比对必然配不上，pp 的库里很可能已有这类重复行）。
        var redundantReplayUserRowIds: [String] = []
        for raw in historyRaws {
            // owner 判定必须在 keep 判断之前，且"命中即消费一次"——保证第 i 个
            // 回放行对上第 i 个**未被占用**的本地行。
            let claim = owners.claimOwner(for: raw)
            if keptIds.contains(raw.id) {
                switch claim {
                case .owner(let owner) where owner != raw.id:
                    unifiedFinalOrderIds.append(owner)
                    redundantReplayUserRowIds.append(raw.id)
                case .duplicate:
                    // [v1.14.31 F1 自愈] 已入库的重复回放行（旧算法误插）：
                    // 同一逻辑消息已由本批更早的行承载 → 旧副本一并清除
                    // （幂等，一次校准收敛）。
                    redundantReplayUserRowIds.append(raw.id)
                default:
                    unifiedFinalOrderIds.append(raw.id)
                }
                continue
            }
            switch claim {
            case .owner(let owner):
                // 防双份：回放 user 行不插，本地行顶替它在 bridge 序里的位置
                unifiedFinalOrderIds.append(owner)
            case .duplicate:
                // [v1.14.31 F1] 同一逻辑消息的超录副本（watchdog 重试重发）：
                // 不插、不占位（位置已由更早的同源行持有）。
                break
            case .unmatched:
                unifiedFinalOrderIds.append(raw.id)
                inserts.append(raw)
            }
        }

        // [Fix v1.14.30] 冗余回放 user 行（同内容已由本地承载行渲染）并入删除。
        // "user 行只增不删" 的初衷是防"删了不回插 = 内容净丢"；这里删的是
        // **重复副本**——内容由 localOwner 行承载且在 unified 序里占位，故安全。
        var seenDeleteIds = Set<String>()
        let allDeleteIds = (deleteIds + redundantReplayUserRowIds)
            .filter { seenDeleteIds.insert($0).inserted }
        let keptCount = dbRows.count - allDeleteIds.count
        return RemoteHistoryReplacePlan(
            inserts: inserts,
            deleteIds: allDeleteIds,
            keptCount: keptCount,
            unifiedFinalOrderIds: unifiedFinalOrderIds
        )
    }

    // MARK: - [stable history ids] 稳定身份合并路径

    /// stable 路径的执行计划。与 `RemoteHistoryReplacePlan` 的关键区别：
    /// **没有 `unifiedFinalOrderIds`**——stable 路径不做全局重排（乱序根因），
    /// 只为**新插入**的行计算落位。
    struct StableReplacePlan {
        /// 需要插入的行（`id` 已是 `bm-{messageUuid}` 形态），按服务端 seq 升序
        let inserts: [RawMessage]
        /// 需要删除的 DB 行 id（仅限本会话 stable 段内被桥撤回的行）
        let deleteIds: [String]
        /// 保留的行数（诊断）
        let keptCount: Int
        /// 落位序列：**已存在的行保持其 sort_order 不动**，只给新插入行分配
        /// 锚点。元素 = (rowId, anchorRowId?) —— anchorRowId 为 nil 表示排到
        /// 本地已有 stable 段之后（append）。
        let placements: [StablePlacement]
        /// 本次是否为纯追加（无删除、全部新行追加到尾部）——供上层判断
        /// 是否可跳过任何重排逻辑。
        let isPureAppend: Bool

        struct StablePlacement {
            let rowId: String
            /// 插入到该行之后；nil = 追加到末尾。
            let afterRowId: String?
        }

        var isEmpty: Bool { inserts.isEmpty && deleteIds.isEmpty }
    }

    /// [stable history ids · C4] 按**稳定身份**合并服务端历史与本地行。
    ///
    /// 与 `planReplace` 的本质差异（对齐 ChatGPT/Claude 远程范式）：
    /// | 维度 | planReplace（旧路径，保留） | planStableReplace（本函数） |
    /// |---|---|---|
    /// | 行身份 | 位置（`bridge-{seg}-{seq}`） | 消息（`bm-{messageUuid}`） |
    /// | 排序真相 | 客户端 renumber 全局重排 | **服务端 seq**，客户端只定位 |
    /// | 缺行处理 | 重排全部 sort_order | 旧行 sort_order **一律不动** |
    /// | 幂等性 | 靠 id 集 + 段规则 | messageUuid 天然幂等 upsert |
    ///
    /// 规则：
    /// 1. **幂等 upsert**：`messageUuid` 已在 DB（`bm-` 行）→ 保留，不插不删。
    /// 2. **不删历史内容**（继承 planReplace 的 R1 教训）：不在本次快照里的老行
    ///    保留——桥侧归档后快照带全量，缺失即真缺失，但仍不删（本地是累计
    ///    缓存，多设备交错时删 = 删别的设备内容）。
    ///    **唯一例外**：`supersededLegacyIds`（同一 seq 已被 `bm-` 行承载的旧
    ///    形态副本）——删它是为了不双份渲染，不是删内容。
    /// 3. **落位**：新行的 `sortOrder` 由「前一条已存在的 stable 行的
    ///    sort_order + 步长」推导，**不触碰任何旧行**。锚点选择 =
    ///    快照中该新行之前最近的一条已落库行；没有则用窗口基之前的最后一条
    ///    本地行（或追加到末尾）。
    ///
    /// - Parameters:
    ///   - stableRaws: 快照转换出的行，`id` 已是 `bm-{messageUuid}`，按服务端
    ///     seq 升序（管线保证）。
    ///   - dbRows: 本地 DB 现有行（按 sort_order 升序）。
    ///   - supersededLegacyIds: 应从 DB 删除的**旧形态冗余副本** id 集。调用方
    ///     用 wire 的 seq 反解旧行 id 得出（见 `RemoteHistoryBackfill`）；默认
    ///     空 = 不删任何东西。
    static func planStableReplace(
        stableRaws: [RawMessage],
        dbRows: [RawMessage],
        supersededLegacyIds: Set<String> = [],
        sortOrderStep: Int = 1000
    ) -> StableReplacePlan {
        let dbIds = Set(dbRows.map { $0.id })
        let dbRowById = Dictionary(
            dbRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var inserts: [RawMessage] = []
        var placements: [StableReplacePlan.StablePlacement] = []
        // 用于锚点推导：随插入推进而更新的「已知最后落位行 id」
        var previousStableRowId: String? = nil
        var deletedAny = false
        var insertedAny = false

        for raw in stableRaws {
            if dbIds.contains(raw.id) {
                // 幂等命中：已在库，保留原 sort_order（不动），仅推进锚点。
                previousStableRowId = raw.id
                continue
            }
            // 新行 → 插入。锚点 = 快照中前一条已落库/已插入的行。
            inserts.append(raw)
            placements.append(.init(rowId: raw.id, afterRowId: previousStableRowId))
            previousStableRowId = raw.id
            insertedAny = true
        }

        // 删除规则：**只删"已被 stable 行取代的旧形态副本"**，绝不删历史内容。
        //
        // 场景（升级路径必现）：老版本把同一条消息写成 `bridge-{ns}-{seg}-{seq}`
        // 行；升级后桥开始注入 messageUuid，回放以 `bm-{uuid}` 插入**同一内容**
        // 的新行。旧行的 seq 与本次快照某条目的 seq 相同 → 内容已有 bm- 行承载
        // → 旧行是纯冗余副本，不删则同一条消息渲染两遍。
        //
        // 判定由调用方给出（`supersededLegacyIds`）——它才拿得到 wire 的
        // seq↔messageUuid 对应关系；纯函数不假装知道 wire 语义。
        // 当前桥协议无"撤回"语义，故除该冗余集合外恒不删。
        let deleteIds: [String] = dbRows
            .map { $0.id }
            .filter { supersededLegacyIds.contains($0) }
            .filter { dbIds.contains($0) }
            // 防御：stable 行自己（bm-）永不作为"被取代的副本"删除——它是
            // 稳定身份的正主。上游若误把 bm- 放进集合（例如把 past- 的索引
            // 与 seq 空间搞混），这里必须挡住，而不是静默删掉刚落库的内容。
            .filter { ReplayRowId.parseStableUuid($0) == nil }
        if !deleteIds.isEmpty { deletedAny = true }

        // 纯追加判定：无删除 + 所有插入都排在已有 stable 段之后。
        let dbHasStableRows = dbRows.contains { ReplayRowId.parseStableUuid($0.id) != nil }
        let isPureAppend = !deletedAny && insertedAny && (
            !dbHasStableRows
                || placements.allSatisfy { placement in
                    guard let anchor = placement.afterRowId else { return dbHasStableRows }
                    return dbRowById[anchor] != nil
                }
        )

        return StableReplacePlan(
            inserts: inserts,
            deleteIds: deleteIds,
            keptCount: dbRows.count,
            placements: placements,
            isPureAppend: isPureAppend
        )
    }

    /// [stable history ids · C4] 把 stable 计划的落位翻译成具体的 sort_order
    /// 赋值。**不重排任何已有行**——只为新行在锚点之后开辟空间。
    ///
    /// 规则（[stable history ids · C4 修订] 中间落位必须腾位）：
    /// - **连续插入**在同一锚点之后时，序号按 step 递增级联。
    /// - **锚点之后紧跟已有 stable 行**：新行序号从 `anchor.sortOrder` 起递增；
    ///   若撞上后一条已有 stable 行的序号，则由 `applyStableHistoryReplace`
    ///   在执行期对**整个 stable 段**重新等距编号（见该方法的 seg 整形步骤）。
    ///   这里只负责"新行相对锚点向前排列"的初值，跨行整形在落库事务里做——
    ///   DB 现状（含并发写入）只有事务里才知道，纯函数不应假装知道。
    /// - 无锚点（纯追加 / DB 无 stable 段）→ 从 `dbMaxSortOrder + step` 起递增。
    ///
    /// 返回 `[rowId: sortOrder]`，仅含需要写入的新行（旧行一律不动）。
    static func stableSortOrders(
        plan: StableReplacePlan,
        dbRows: [RawMessage],
        sortOrderStep: Int = 1000
    ) -> [String: Int] {
        let rowById = Dictionary(
            dbRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let dbMaxSortOrder = dbRows.map { $0.sortOrder }.max() ?? 0

        var result: [String: Int] = [:]
        var lastAssigned = dbMaxSortOrder

        for placement in plan.placements {
            let base: Int
            if let anchorId = placement.afterRowId {
                if let anchorRow = rowById[anchorId] {
                    base = anchorRow.sortOrder
                } else if let assigned = result[anchorId] {
                    base = assigned
                } else {
                    base = lastAssigned
                }
            } else {
                base = lastAssigned
            }
            let next = base + sortOrderStep
            result[placement.rowId] = next
            lastAssigned = next
        }
        return result
    }

    /// [stable history ids · C4 修订] **落位续号**：先把 stable 段按服务端
    /// 权威顺序重排成**等距、且与段外行不冲突**的连续序号，再返回需要 UPDATE
    /// 的全部 stable 行 → 新序号。
    ///
    /// 为什么必须在事务里做：`stableSortOrders` 的初值只有"相对锚点靠后"的
    /// 信息。当真发生**中间落位**（桥窗口滑过 trim 旧行、随后补历史空洞）时，
    /// 锚点后紧邻已有行，新行初值会 ≥ 后者序号 → 渲染到后面 = 顺序错。DB 的
    /// 并发现状只有事务里知道，故整形放在落库前基于**当前 DB 行**做一次。
    ///
    /// 整形**只改序号、不改身份**：行的 `id`/内容/`clientMessageId` 一律不动。
    /// 这与旧路径 renumber 有本质区别——后者连**非 stable 行**都卷进 1..M
    /// 重排，是"本地窗口外旧消息被散开"的病根。
    ///
    /// 算法（B-3/B-4/B-6 修订版）：
    ///
    /// 1. **固定步长**。`step` 是常量 `defaultStep`，**绝不**依据当前跨度动态
    ///    计算。旧实现取 `span / (count-1)`，有两个后果：
    ///    - *越界*（B-3）：`span < count-1` 时 `step` 被压到 1，序号一路涨到
    ///      `lo + count - 1`，**冲出段内区间**，撞上后面的段外行 → 顺序不确定。
    ///    - *非幂等*（B-4）：同区间同顺序，第一次算出 step 666，写完后跨度
    ///      变了，第二次算出 step 500 → **前几行序号全变**，每次同步都写库。
    ///    固定步长让"同顺序 ⇒ 同结果"，第二次跑天然零写入。
    ///
    /// 2. **越界时整体平移腾位，而非压缩步长**。若 `base + step*(n-1)` 会撞上
    ///    段外行（或越过 `upperBound`），整段向下平移到能容纳的最小 `base`；
    ///    平移只改 stable 行序号，段外行一个不动。
    ///
    /// 3. **混合形态也算进去**（B-6）。段内既有 `bm-` 行也可能残留旧形态
    ///    `bridge-*` 行。旧实现只把 `bm-` 行纳入序列，于是整形后 stable 序号
    ///    会与那些"没被算进去"的旧行交错/撞号。现在把 `orderedStableIds`
    ///    里**所有**已知行（无论形态）都当作段内占位，序号空间统一分配。
    ///
    /// - Returns: `[rowId: sortOrder]`。顺序已严格递增/无新行时返回空字典
    ///   （幂等校准零写入——稳定路径"不该动的绝不动"的体现）。
    static func stableSegmentRenumber(
        orderedStableIds: [String],
        newRowOrders: [String: Int],
        dbRows: [RawMessage],
        defaultStep: Int = 1000
    ) -> [String: Int] {
        // [B-6] 段内任一已知行（bm- 新形态 或 旧形态回放行）都参与占位。
        let knownById = Dictionary(
            dbRows.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let stableIds = orderedStableIds.filter {
            knownById[$0] != nil || newRowOrders[$0] != nil
        }
        guard !stableIds.isEmpty else { return [:] }

        // 段内现有行的序号（新行还没有）。段内**所有**形态都算，B-6。
        let existingOrders = stableIds.compactMap { knownById[$0]?.sortOrder }
        guard !existingOrders.isEmpty else {
            // 段内全是新行（首次落地）→ 用 stableSortOrders 的初值即可。
            return newRowOrders
        }

        let count = stableIds.count
        // 段内区间 [lo, hi]。
        let lo = existingOrders.min()!
        let hi = existingOrders.max()!

        // [B-3] 段内现有行的**位置区间** [lo, hi] 不是硬约束——它只是历史上的
        // 落位结果。真正不能越过的是**段外行**：stable 段整体必须排在它前面。
        // 段内区间装不下时，整段向下平移腾位（只改 stable 行序号，段外行一个
        // 不动），而不是像旧实现那样按"当前跨度"去压缩 step。
        let stableIdSet = Set(stableIds)
        let upperBound: Int? = dbRows
            .filter { !stableIdSet.contains($0.id) && $0.sortOrder > lo }
            .map(\.sortOrder)
            .min()

        // 可用空间：从段首之后到第一个段外行之前。没有段外行时无上界。
        //
        // ⚠️ step 必须**由这个上界推导**（而不是由当前跨度推导），否则：
        //  · 由当前跨度推导 → 每次写库后跨度变了 → step 变 → 非幂等（B-4）；
        //  · 完全不推导 → step 跨出可用空间 → 撞段外行（B-3，本次实测）。
        // 上界由 DB 的**段外行**决定，段内数据怎么排都不会改变它，所以
        // "同输入 ⇒ 同 step"，幂等仍然成立。
        var step = max(defaultStep, 1)
        // 平移后的 base：优先保持段首位置，空间不足时下移。
        var base = lo
        if let bound = upperBound {
            // 段内 n 行必须都严格小于 bound。
            let room = bound - 1 // 可用的最大序号
            if count > 1, room > 0 {
                // 每行至少间隔 1，且不得超过 defaultStep。
                let maxStep = max(room / (count - 1), 1)
                step = min(step, maxStep)
            } else if room <= 0 {
                // 段外行就贴在段首之前——无可腾挪空间，保持原样不动。
                return [:]
            }
            // 收尾：整段必须放得下。
            let needed = step * (count - 1)
            if base + needed > room {
                base = max(room - needed, 0)
            }
        }
        base = min(base, lo)

        var result: [String: Int] = [:]
        for (index, id) in stableIds.enumerated() {
            let target = base + step * index
            if let row = knownById[id] {
                // 已存在行：只在序号真的变了才写（幂等零写入）。
                if row.sortOrder != target { result[id] = target }
            } else {
                // 新行：必须写。
                result[id] = target
            }
        }
        return result
    }

    /// 校准事务的最终行序列（`ChatStore.replaceRemoteHistory` 第 3 步 renumber
    /// 的定序来源）。抽成纯函数以便单测——DB 事务本身依赖 sqlite，但
    /// "哪些行排前/排后"的规则是纯逻辑，pp 真机两轮乱序（07:06 user 气泡
    /// 置顶 / 09-11 "在吗"被甩到第一条）都栽在这里。
    ///
    /// 规则（三段拼接）：
    /// 1. `replayBefore` — 不在本次 history 序里的 bridge-{seq}/past-{index}
    ///    老回放行（trimHistory 100 条窗口外的幸存者，只增不删）→ 历史最早。
    /// 2. `unifiedFinalOrderIds` 序（bridge history + 防双份命中的本地行替换）
    ///    → 中段主体。缺行时用 finalOrder 里的同 id 行兜底。
    /// 3. `liveAfter` — 其余不在 history 序里的行（live UUID：用户刚发的
    ///    消息、流式未完 assistant 行；bridge history 尚未承载 = 语义最新）
    ///    → 排最后。旧规则把它们排最前 = 乱序复发根因（见 §3 注释）。
    ///
    /// 组内均保持传入顺序（caller 已按现有 sort_order 升序给 `retainedRows`），
    /// 不重排。
    static func orderedRowSequence(
        unifiedFinalOrderIds: [String],
        finalOrder: [RawMessage],
        retainedRows: [RawMessage],
        rowById: [String: RawMessage],
        segmentRanks: [String: Int] = [:],
        settledSortOrderFloor: Int? = nil
    ) -> [RawMessage] {
        var before: [RawMessage] = []
        var settled: [RawMessage] = []
        var after: [RawMessage] = []
        for row in retainedRows {
            // bridge-/past- 前缀 = 回放行（老历史，排前）；其余（live UUID）
            // = 本地新内容（排后）。前缀判定收敛到 ReplayRowId（[Fix v1.14.29]）。
            if ReplayRowId.isReplayRow(row.id) {
                before.append(row)
            } else if row.role == .user, let floor = settledSortOrderFloor, row.sortOrder <= floor {
                // [Fix v1.14.30.1 / F1] 已落座 live user 行：上次校准写过它的
                // 位置（sort_order ≤ 水位），此后 bridge 历史因 trim/resume 不再
                // 承载 ≠ 新内容。原规则甩尾 =「你好」排到最新一条（pp 实锤）。
                // 回放区之后、history 主体之前稳定落座；assistant live 行为不变
                // （流式未完行仍 after，v1.14.27 语义保持）。
                settled.append(row)
            } else {
                after.append(row)
            }
        }
        // [Fix v1.14.30] 段级定序：多段并存（换过 bridge 会话 / 多设备共享同一
        // chat 会话）时，回放区按 (段首见次序, seq) 排——先见到的段 = 更早的
        // 历史，同段内 seq 单调。past 行恒最先（磁盘历史早于任何 bridge 会话）。
        before = Self.sortedReplayRows(before, segmentRanks: segmentRanks)
        var sequence: [RawMessage] = before
        sequence.append(contentsOf: settled)
        for id in unifiedFinalOrderIds {
            if let row = rowById[id] {
                sequence.append(row)
            } else if let fallback = finalOrder.first(where: { $0.id == id }) {
                sequence.append(fallback)
            }
        }
        sequence.append(contentsOf: after)
        return sequence
    }

    /// 判定 bridge history 末尾是否处于"turn 进行中"。
    ///
    /// bridge 端 result（turn 结束）会 append 进 history（session.ts:614）；
    /// 进行中的 turn 尾部是 assistant / tool_result / user_input（result
    /// 尚未产生）。用于恢复态 isProcessing 衔接（发送键 → 停止键）。
    ///
    /// - Parameter lastWireType: fetch 返回的最后一条 wire 消息 type
    ///   （`history` 信封内 messages[] 的末条；nil = 空 history → idle）
    static func isTurnInProgress(lastWireType: String?) -> Bool {
        guard let lastWireType else { return false }
        switch lastWireType {
        case "result", "error", "status":
            return false
        default:
            // assistant / tool_result / user_input / 其他未知类型 → 视为进行中
            return true
        }
    }

    // MARK: - 增量快路径准入（[Fix v1.14.29] 远端乱序根因 A 的闸门）

    /// delta 增量**只含本次新条目**，而 renumber 的定序契约要求**全量
    /// history 序**——把残缺序喂进 `planReplace` 会让 `unifiedFinalOrderIds`
    /// 只剩那几条新行，`orderedRowSequence` 于是把所有不在序里的 live UUID 行
    /// （= 用户自己的**全部**发言）判为"历史未承载的最新内容"排到末尾：
    ///
    ///   pp 真机 2026-09-11 08:06 日志：空 delta → renumber-only →
    ///   重进后 "你好"/"你什么模型" 落在会话最末（[6]/[7]）。
    ///
    /// 因此 delta 只在**顺序已被一次成功全量校准封版**（orderSealed）且
    /// **纯追加**（所有新条目 seq 都大于本地现有最大 bridge seq）时才允许
    /// 跳过 renumber；任一不满足 → caller 直接 fallback 全量（= v1.14.22
    /// 已验证路径，不劣于现状）。
    ///
    /// - Parameters:
    ///   - orderSealed: 本会话已由成功全量校准写入定序封版标记
    ///   - deltaSeqs: 本次增量条目的 historySeq
    ///   - dbMaxBridgeSeq: 本地 DB 现有 bridge 行最大 seq（无基线 → nil）
    static func deltaFastPathAllowed(orderSealed: Bool, deltaSeqs: [Int], dbMaxBridgeSeq: Int?) -> Bool {
        guard orderSealed else { return false }
        guard let dbMaxBridgeSeq else { return false }
        guard !deltaSeqs.isEmpty else { return false }
        for seq in deltaSeqs where seq <= dbMaxBridgeSeq {
            return false
        }
        return true
    }

    // MARK: - delta 插入位置（[Fix v1.14.30] 对抗审查 S4）

    /// delta 增量行的插入计划：锚点 sort_order + 需要整体后移的行（从后往前）。
    ///
    /// 为什么不能盲追加 `max + 1`：DB 里可能已有"bridge history 尚未承载的
    /// live 行"（用户刚发的 U2，此时**上一轮**的回复才到达 delta）——盲追加会
    /// 把 U1 的回复排到 U2 **之后**，顺序错到下一次全量校准才修（S4 审查）。
    ///
    /// 锚点规则：
    /// 1. 本批 delta **认领到的最后一个 live 行**（unified 序里出现、DB 已
    ///    存在、且不是本批插入行）→ delta 内容在它之后（它是载体，不是新内容）；
    /// 2. 没有认领行（delta 内容全部位于 trailing live 行之前）→ 最后一个
    ///    回放行的位置。
    /// 锚点之后的行整体后移 `inserts.count` 位，插入行占住腾出的窗口。
    ///
    /// - Returns: `anchorOrder`（插入行从 anchorOrder + 1 起）与 `rowsToShift`
    ///   （已按 sort_order 降序，调用方依序 +count 即可）
    ///
    /// ⚠️ [Fix v1.14.30] 前置条件：`deltaInsertIsSafe == true`（纯尾段
    /// 插入）。夹心批次单一锚点必然错序——调用方必须先闸形态（见
    /// `deltaInsertIsSafe`；ChatStore 侧有后备闸拒绝执行）。
    static func deltaInsertPlan(
        unifiedFinalOrderIds: [String],
        inserts: [RawMessage],
        dbRows: [RawMessage]
    ) -> (anchorOrder: Int, rowsToShift: [RawMessage]) {
        let insertedIdSet = Set(inserts.map { $0.id })
        let rowById = Dictionary(uniqueKeysWithValues: dbRows.map { ($0.id, $0) })
        let anchorOrder: Int
        if let claimedId = unifiedFinalOrderIds.last(where: { !insertedIdSet.contains($0) }),
           let claimedRow = rowById[claimedId] {
            anchorOrder = claimedRow.sortOrder
        } else {
            anchorOrder = dbRows
                .filter { ReplayRowId.isReplayRow($0.id) }
                .map { $0.sortOrder }
                .max() ?? -1
        }
        let rowsToShift = dbRows
            .filter { $0.sortOrder > anchorOrder }
            .sorted { $0.sortOrder > $1.sortOrder }
        return (anchorOrder, rowsToShift)
    }

    /// [Fix v1.14.30 / 对抗审查 2·前提 2] delta 快路径的**形态安全性**：
    /// 插入行必须全部位于 unified 序的**纯尾段**（最后一个非插入行之后）。
    /// 「夹心」形态——插入行 → 认领行 →（插入行）——单一锚点规则只能把整批
    /// 插到最后认领行之后，夹在前段的插入行必然错序：
    ///   · 一批 delta 跨多个本地回合（快速连发两轮、中间无校准窗口），
    ///     U1 的回复被排到 U3 的输入之后；
    ///   · cursor 停在上轮回复中段（上次校准回滚），窗口同时含回复尾段
    ///     与新 user_input。
    /// - Returns: false = 混合批次，调用方必须放弃快路径（fallback 全量校准）。
    static func deltaInsertIsSafe(unifiedFinalOrderIds: [String], inserts: [RawMessage]) -> Bool {
        let insertedIdSet = Set(inserts.map { $0.id })
        guard let lastKeptIndex = unifiedFinalOrderIds.lastIndex(where: { !insertedIdSet.contains($0) }) else {
            return true  // 全是插入行（无认领行）→ 锚点 = 最后回放行，无夹心
        }
        guard let firstInsertIndex = unifiedFinalOrderIds.firstIndex(where: { insertedIdSet.contains($0) }) else {
            return true  // 没有插入行
        }
        return firstInsertIndex > lastKeptIndex
    }

    // MARK: - 段级定序（[Fix v1.14.30]）

    /// 回放区排序：past 行最先（按 index），随后按 (段首见次序, seq)。
    /// 段缺失/未登记时用现有相对顺序兜底（稳定排序由原始下标保证）。
    private static func sortedReplayRows(_ rows: [RawMessage], segmentRanks: [String: Int]) -> [RawMessage] {
        guard rows.count > 1 else { return rows }
        return rows.enumerated()
            .sorted { lhs, rhs in
                replaySortKey(lhs.element, rank: rank(of: lhs.element, segmentRanks: segmentRanks), index: lhs.offset)
                    < replaySortKey(rhs.element, rank: rank(of: rhs.element, segmentRanks: segmentRanks), index: rhs.offset)
            }
            .map { $0.element }
    }

    /// past 行 → -1（磁盘历史最早）；bridge 行 → 段 rank（未登记 → Int.max，
    /// 即排在已登记段之后、但仍保持彼此现有顺序）。
    private static func rank(of row: RawMessage, segmentRanks: [String: Int]) -> Int {
        if row.id.hasPrefix("past-") { return -1 }
        guard let segment = ReplayRowId.parseSegment(row.id) else { return Int.max }
        return segmentRanks[segment] ?? Int.max
    }

    private static func replaySortKey(_ row: RawMessage, rank: Int, index: Int) -> (Int, Int, Int) {
        // [Fix v1.14.30 / 对抗审查 S3] 段未登记（rank == Int.max：老形态无段 /
        // rank 表丢失）→ **不参与 seq 排序**，用原始下标兜底保持现有相对顺序
        // ——这是本函数文档写明的契约。旧实现仍按 seq 比较，直接违反注释：
        // 两个未登记段的行会被 seq 交叉重排（`[cccc-2, dddd-1]` 变
        // `[dddd-1, cccc-2]`），且与 past 特判叠加后跟既有测试互相矛盾
        // （CI 门里两条期望必红其一）。
        if rank == Int.max { return (Int.max, index, index) }
        let seq = ReplayRowId.parseBridgeSeq(row.id) ?? ReplayRowId.parsePastIndex(row.id) ?? Int.max
        return (rank, seq, index)
    }

    // MARK: - 内容匹配（已迁出）

    // [Fix v1.14.30] 用户正文归一化/配对（附件 XML 剥离、同文本 occurrence
    // 队列）已迁到独立模块 `RemoteHistoryOwnerIndex`（见
    // RemoteHistoryIdentity.swift）——"身份对账"与"定序"是两个改变的理由，
    // 不再混在本文件里。本文件只保留定序（planReplace / orderedRowSequence /
    // deltaFastPathAllowed / isTurnInProgress）。
}
