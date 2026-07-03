import Foundation

public protocol TranslationEngine: Sendable {
    var id: String { get }                 // "apple"/"llm"/"google"/"deepl"/"youdao"
    var isUnofficial: Bool { get }         // UI 标注"非官方接口,可能不稳定"
    var perRequestCharLimit: Int { get }
    func translate(_ texts: [String], direction: TranslationDirection) async throws -> [String]
}

/// 供测试注入的 URLSession 协议封装
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}
extension URLSession: HTTPClient {}
