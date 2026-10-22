// Schlüssel und Signaturen der automatischen Updates (Sparkle, EdDSA/ed25519) — unabhängig von Sparkles Werkzeugen,
// damit eine Signatur gegen genau den Schlüssel geprüft wird, den die gebaute App kennt.
//
//   swift scripts/update-signature.swift verify <Knips.app> <datei> <signatur>
//       Prüft eine Signatur (base64, von sign_update) gegen SUPublicEDKey aus der Info.plist der App.
//   swift scripts/update-signature.swift new-key <privat-datei>
//       Wegwerf-Schlüssel für Tests: schreibt den privaten Schlüssel (base64 wie `generate_keys -x`, nur für den
//       Besitzer lesbar) in eine neue Datei und gibt den öffentlichen aus. Echte Releases signiert scripts/release.sh
//       mit dem Schlüssel aus dem Schlüsselbund.
import CryptoKit
import Foundation

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("✗ \(message)\n".utf8))
    exit(code)
}

let args = CommandLine.arguments
switch (args.count, args.count > 1 ? args[1] : "") {
case (5, "verify"):
    let app = URL(fileURLWithPath: args[2])
    guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
        fail("\(app.path) hat keine Info.plist.")
    }
    guard let encoded = info["SUPublicEDKey"] as? String, let raw = Data(base64Encoded: encoded), raw.count == 32,
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        fail("SUPublicEDKey in \(app.lastPathComponent) fehlt oder ist kein EdDSA-Schlüssel.")
    }
    guard let signature = Data(base64Encoded: args[4]), signature.count == 64 else { fail("Die Signatur ist kein EdDSA-Format.") }
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe) else { fail("\(args[3]) nicht lesbar.") }
    guard key.isValidSignature(signature, for: data) else {
        fail("Signatur von \(URL(fileURLWithPath: args[3]).lastPathComponent) passt nicht zu SUPublicEDKey \(encoded).")
    }
    print("✓ Signatur passt zu SUPublicEDKey \(encoded) (\(data.count) Byte)")
case (3, "new-key"):
    let path = args[2]
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) gibt es schon.") }
    let key = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                         attributes: [.posixPermissions: 0o600]) else { fail("\(path) nicht schreibbar.") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
default:
    fail("Aufruf: swift scripts/update-signature.swift verify <Knips.app> <datei> <signatur> | new-key <privat-datei>", code: 2)
}
