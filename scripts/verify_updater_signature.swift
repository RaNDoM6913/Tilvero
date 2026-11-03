#!/usr/bin/env swift
// Public-key-only verification: never opens Keychain or generates signing keys.
import CryptoKit
import Foundation

let args = CommandLine.arguments
if args.count != 4 {
    FileHandle.standardError.write(Data("usage: verify_updater_signature.swift <public-key-base64> <signature-base64> <file>\n".utf8))
    exit(2)
}
do {
    guard let publicKey = Data(base64Encoded: args[1]), publicKey.count == 32,
          let signature = Data(base64Encoded: args[2]), signature.count == 64 else {
        throw NSError(domain: "Tilvero.UpdaterSignature", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let content = try Data(contentsOf: URL(fileURLWithPath: args[3]), options: .mappedIfSafe)
    guard key.isValidSignature(signature, for: content) else { throw NSError(domain: "Tilvero.UpdaterSignature", code: 2) }
} catch {
    FileHandle.standardError.write(Data("Updater signature verification failed.\n".utf8))
    exit(1)
}
