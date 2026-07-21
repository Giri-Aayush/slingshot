// Lifetime license issuance for Slingshot Pro. No servers: keys are Ed25519
// signed payloads the app verifies offline against the embedded public key.
//   swift scripts/license-tool.swift keygen
//   swift scripts/license-tool.swift issue name@example.com
//   swift scripts/license-tool.swift verify SLINGSHOT-...
import CryptoKit
import Foundation

let keyPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".slingshot-license-key")

func b64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
func unb64url(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "keygen":
    if FileManager.default.fileExists(atPath: keyPath.path) {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyPath))
        print("existing public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
    } else {
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: keyPath, options: .completeFileProtection)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
        print("public key: \(key.publicKey.rawRepresentation.base64EncodedString())")
        print("private seed written to \(keyPath.path). Back it up; it mints every license.")
    }
case "issue":
    guard args.count > 2 else { fatalError("usage: license-tool.swift issue <email>") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyPath))
    let payload: [String: Any] = ["product": "slingshot-pro", "email": args[2],
                                  "lifetime": true,
                                  "issued": ISO8601DateFormatter().string(from: Date())]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    let signature = try key.signature(for: data)
    print("SLINGSHOT-\(b64url(data)).\(b64url(signature))")
case "verify":
    guard args.count > 2 else { fatalError("usage: license-tool.swift verify <key>") }
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: keyPath))
    let parts = args[2].replacingOccurrences(of: "SLINGSHOT-", with: "").split(separator: ".")
    guard parts.count == 2, let payload = unb64url(String(parts[0])), let sig = unb64url(String(parts[1])),
          key.publicKey.isValidSignature(sig, for: payload) else {
        print("INVALID")
        exit(1)
    }
    print("VALID  \(String(data: payload, encoding: .utf8) ?? "")")
default:
    fatalError("usage: license-tool.swift keygen | issue <email> | verify <key>")
}
