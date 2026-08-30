import Foundation

/// 源 int key 解析器。原版 ComicType.value = sourceKey.hashCode（跨版本/
/// 平台不稳定），因此历史数据一律经 implicitData['sourceTypeRegistry']
/// 的 int→key 注册表解析；Swift 端沿用该机制：导入数据按注册表还原，
/// 新源分配稳定 int 并登记（随 implicitData 持久化、随备份同步）。
public final class SourcePlatformResolver: @unchecked Sendable {
    public static let shared = SourcePlatformResolver()

    private let lock = NSLock()
    private var legacyIntKeys: [Int: String] = [:]

    /// 学习回调：新的 int→key 映射产生时触发（应持久化到 implicitData）。
    public var onLegacyKeyLearned: (@Sendable (Int, String) -> Void)?

    public init() {}

    /// 从 implicitData 注册表恢复。
    public func registerLegacyIntSourceKeys(_ mapping: [Int: String]) {
        lock.lock()
        for (key, value) in mapping {
            legacyIntKeys[key] = value
        }
        lock.unlock()
    }

    public func registerLegacyIntSourceKey(_ legacyIntType: Int, _ sourceKey: String) {
        lock.lock()
        let existed = legacyIntKeys[legacyIntType]
        if existed == nil {
            legacyIntKeys[legacyIntType] = sourceKey
        }
        lock.unlock()
        if existed == nil {
            onLegacyKeyLearned?(legacyIntType, sourceKey)
        }
    }

    /// int → 源 key（未知返回 nil）。
    public func resolve(_ legacyIntType: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return legacyIntKeys[legacyIntType]
    }

    /// 源 key → int。已知源复用注册表中的旧值（保证与导入数据一致）；
    /// 新源以稳定哈希分配并登记。
    public func intKey(for sourceKey: String) -> Int {
        lock.lock()
        if let existing = legacyIntKeys.first(where: { $0.value == sourceKey })?.key {
            lock.unlock()
            return existing
        }
        lock.unlock()
        let newKey = LegacyHash.hash(sourceKey)
        registerLegacyIntSourceKey(newKey, sourceKey)
        return newKey
    }

    public func snapshot() -> [Int: String] {
        lock.lock()
        defer { lock.unlock() }
        return legacyIntKeys
    }
}

/// 确定性字符串哈希（djb2 变体）。仅用于给「注册表中不存在的新源」分配
/// int key；值本身与 Dart hashCode 无关，但一经登记便永久稳定。
public enum LegacyHash {
    public static func hash(_ string: String) -> Int {
        var hash: UInt64 = 5381
        for byte in string.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Int(truncatingIfNeeded: hash & 0x7FFF_FFFF_FFFF_FFFF)
    }
}

/// 漫画标识：type 为 0（local）或源 key 的注册表 int（对齐 ComicType）。
public struct ComicID: Hashable, Sendable, Codable {
    public var id: String
    public var type: Int

    public init(id: String, type: Int) {
        self.id = id
        self.type = type
    }

    public static let local = 0

    public var isLocal: Bool { type == ComicID.local }

    public var sourceKey: String? {
        guard !isLocal else { return "local" }
        return SourcePlatformResolver.shared.resolve(type)
    }

    public static func forSource(_ sourceKey: String) -> Int {
        SourcePlatformResolver.shared.intKey(for: sourceKey)
    }
}
