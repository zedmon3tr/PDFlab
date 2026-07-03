import Foundation
import Security

/// 简单的 Keychain 封装,用于持久化 LLM API Key 等敏感信息。
/// 使用 kSecClassGenericPassword,service 固定为 "com.pdflab.app",account 为调用方传入的 key。
public enum KeychainStore {
    private static let service = "com.pdflab.app"

    /// 保存(或覆盖已存在的)值。
    public static func save(key: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        // 先删除已存在的条目,再写入,以实现"覆盖保存"的语义。
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PDFLabError.exportWriteFailed("Keychain save failed: OSStatus \(status)")
        }
    }

    /// 读取值;不存在或读取失败返回 nil。
    public static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 删除值;不存在时静默忽略。
    public static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
