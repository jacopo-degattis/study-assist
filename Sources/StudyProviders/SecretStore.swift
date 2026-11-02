import Foundation
import Security
import StudyDomain

/// Secrets never touch the database. Only a reference is stored there.
public protocol SecretStore: Sendable {
    func store(secret: String, for reference: String) throws
    func secret(for reference: String) throws -> String?
    func deleteSecret(for reference: String) throws
}

public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "com.studyapp.credentials") {
        self.service = service
    }

    public func store(secret: String, for reference: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw AppError.persistenceFailure("The Keychain rejected the update (status \(updateStatus)).")
        }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AppError.persistenceFailure("The Keychain rejected the item (status \(status)).")
        }
    }

    public func secret(for reference: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw AppError.persistenceFailure("The Keychain could not read the item (status \(status)).")
        }
    }

    public func deleteSecret(for reference: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.persistenceFailure("The Keychain could not delete the item (status \(status)).")
        }
    }
}

/// Test double; never used by the app.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var secrets: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func store(secret: String, for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[reference] = secret
    }

    public func secret(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[reference]
    }

    public func deleteSecret(for reference: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: reference)
    }
}
