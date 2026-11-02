#!/usr/bin/env swift
import CryptoKit
import Foundation

// Public inputs only: verification key, archive path, and EdDSA signature.
guard CommandLine.arguments.count == 4,
    let rawKey = Data(base64Encoded: CommandLine.arguments[1]),
    let signature = Data(base64Encoded: CommandLine.arguments[3]) else { exit(1) }
let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
guard key.isValidSignature(signature, for: data) else {
    fputs("Update archive signature does not match the app's public key.\n", stderr)
    exit(1)
}
print("Update archive EdDSA signature verified.")
