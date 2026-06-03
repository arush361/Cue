//
//  AnthropicAPIKeychain.swift
//  leanring-buddy
//
//  Stores the user's Anthropic API key in the macOS Keychain so the app
//  can talk to api.anthropic.com directly without bundling a key into the
//  binary or routing through a proxy.
//
//  Why Keychain instead of UserDefaults: a sk-ant-... key is a credential.
//  UserDefaults is a plist on disk that any process running as the user
//  can read. Keychain entries are sandboxed per app (by code-signing
//  identity) and never readable as flat text.
//
//  Service: "com.cue.anthropic-api-key", account: "default". A single
//  key per install — multi-account isn't a need today.
//

import Foundation
import Security

enum AnthropicAPIKeychain {
    private static let service = "com.cue.anthropic-api-key"
    private static let account = "default"

    /// Save (or replace) the key in Keychain. Trims whitespace; empty
    /// strings clear the entry rather than storing an empty value.
    @discardableResult
    static func save(_ apiKey: String) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clear()
            return true
        }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Try to update an existing entry first; if no entry exists, add.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Returns the stored key, or nil if none is saved.
    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the stored key. No-op if none was saved.
    @discardableResult
    static func clear() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// True if a non-empty key is saved.
    static var hasSavedKey: Bool {
        guard let key = load() else { return false }
        return !key.isEmpty
    }

    /// Last 4 chars for UI display ("sk-ant-…abcd"). Returns nil if no key.
    static var savedKeyLastFour: String? {
        guard let key = load(), key.count >= 4 else { return nil }
        return String(key.suffix(4))
    }
}
