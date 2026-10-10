import Foundation
import Security

/// The Zipline token, kept out of UserDefaults.
enum Keychain {
    private static let service = "io.github.tangheng05.clippeek"

    /// An item another app owns can't be replaced, so a new token then goes under a new account.
    private static var account: String {
        get { UserDefaults.standard.string(forKey: "tokenAccount") ?? "zipline" }
        set { UserDefaults.standard.set(newValue, forKey: "tokenAccount") }
    }

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Can block on the system password prompt, so call it off the main thread.
    static func token() -> String? {
        var search = query(account)
        search[kSecReturnData as String] = true
        var result: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func setToken(_ token: String?) {
        if SecItemDelete(query(account) as CFDictionary) == errSecInvalidOwnerEdit {
            account = "zipline-\(UUID().uuidString)"
        }
        guard let token, !token.isEmpty else { return }
        var item = query(account)
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
