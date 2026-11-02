#!/usr/bin/env swift
// Run only with explicit approval to create the GitHub signing secret.
// The private seed goes directly to gh's stdin; only the public key is saved.
import CryptoKit
import Foundation

let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let publicFile = package.appendingPathComponent("update-signing.json")
guard !FileManager.default.fileExists(atPath: publicFile.path) else {
    fatalError("Public key already exists; refusing to rotate the update signing identity.")
}
func github(_ arguments: [String], input: Data? = nil) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh"] + arguments
    let output = Pipe()
    process.standardOutput = output
    let pipe = Pipe()
    process.standardInput = pipe
    try process.run()
    if let input { try pipe.fileHandleForWriting.write(contentsOf: input) }
    try pipe.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    return data
}
let repo = "gh123man/QEQ"
let names = try github(["secret", "list", "--repo", repo, "--json", "name"])
guard !String(decoding: names, as: UTF8.self).contains("QEQ_SPARKLE_PRIVATE_ED_KEY") else {
    fatalError("GitHub signing secret already exists; refusing to replace it.")
}
let key = Curve25519.Signing.PrivateKey()
let privateInput = Data(key.rawRepresentation.base64EncodedString().utf8)
_ = try github(["secret", "set", "QEQ_SPARKLE_PRIVATE_ED_KEY", "--repo", repo], input: privateInput)
let publicData = try JSONSerialization.data(
    withJSONObject: ["publicEDKey": key.publicKey.rawRepresentation.base64EncodedString()], options: [.prettyPrinted, .sortedKeys])
try (publicData + Data([10])).write(to: publicFile, options: .atomic)
print("Configured QEQ's GitHub update-signing secret and public key. No private key was written to disk.")
