import CryptoKit
import Foundation

// MARK: - Slingshot Pro lifetime licenses

/// A verified lifetime license.
public struct ProLicense: Equatable {
    public let email: String
    public let issued: String
}

/// The production license public key. Keys are minted offline by
/// scripts/license-tool.swift and verified here with no server involved.
public let productionLicenseKey = "VKi9pCdIDaVIB9M6RboqsOFlFpdZDHoDonTwdgXxwk8="

/// Validates a license key string. Pure and offline: base64url payload and
/// Ed25519 signature, checked against the given public key.
public func validateLicense(_ key: String, publicKeyBase64: String = productionLicenseKey) -> ProLicense? {
    func unb64url(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("SLINGSHOT-") else { return nil }
    let parts = trimmed.dropFirst("SLINGSHOT-".count).split(separator: ".")
    guard parts.count == 2,
          let payload = unb64url(String(parts[0])),
          let signature = unb64url(String(parts[1])),
          let keyData = Data(base64Encoded: publicKeyBase64),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
          publicKey.isValidSignature(signature, for: payload),
          let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
          object["product"] as? String == "slingshot-pro",
          object["lifetime"] as? Bool == true,
          let email = object["email"] as? String
    else { return nil }
    return ProLicense(email: email, issued: object["issued"] as? String ?? "")
}
