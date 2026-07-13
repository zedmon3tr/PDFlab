import Foundation
import Security

/// 简单的 Keychain 封装,用于持久化各官方云服务 API Key 等敏感信息。
/// 使用 kSecClassGenericPassword,service 固定为 "com.pdflab.app",account 为调用方传入的 key。
public enum KeychainStore {
    private static let service = "com.pdflab.app"

    public enum LookupResult: Equatable, Sendable {
        case found(String)
        case missing
    }

    /// 保存(或覆盖已存在的)值。
    public static func save(key: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // 原地更新可确保失败时旧值仍在；只有条目确实不存在才新增。
        let update = [kSecValueData as String: data]
        var attributes = query
        attributes[kSecValueData as String] = data
        try performUpsert(
            update: { SecItemUpdate(query as CFDictionary, update as CFDictionary) },
            add: { SecItemAdd(attributes as CFDictionary, nil) })
    }

    static func performUpsert(update: () -> OSStatus, add: () -> OSStatus) throws {
        let updateStatus = update()
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PDFLabError.keychainFailure(updateStatus)
        }
        let addStatus = add()
        guard addStatus == errSecSuccess else {
            throw PDFLabError.keychainFailure(addStatus)
        }
    }

    /// 读取值;不存在或读取失败返回 nil。
    public static func load(key: String) -> String? {
        guard case .found(let value) = try? lookup(key: key) else { return nil }
        return value
    }

    /// Strict lookup used by migrations that must distinguish absence from Keychain failure.
    public static func lookup(key: String) throws -> LookupResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PDFLabError.keychainFailure(status)
        }
        return .found(value)
    }

    /// 删除值;不存在时静默忽略。
    public static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PDFLabError.keychainFailure(status)
        }
    }
}
