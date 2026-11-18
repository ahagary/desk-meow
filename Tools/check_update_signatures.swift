import Foundation
import CryptoKit

// Independent verification of generated release artifacts using only the public
// key shipped to users. No signing key or Keychain access is needed here.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "UpdateChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func capture(_ pattern: String, in text: String) throws -> String {
    let expression = try NSRegularExpression(pattern: pattern)
    guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else {
        throw NSError(domain: "UpdateChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少签名字段：\(pattern)"])
    }
    return String(text[range])
}

do {
    let args = CommandLine.arguments
    guard args.count == 4 else { throw NSError(domain: "UpdateChecks", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "usage: check_update_signatures.swift appcast.xml update.zip updates.json"]) }
    let feed = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
    let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[3]))) as! [String: String]
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: configuration["public_ed_key"]!)!)
    let xml = String(decoding: feed, as: UTF8.self)
    let feedSignature = Data(base64Encoded: try capture("edSignature: ([A-Za-z0-9+/=]+)", in: xml))!
    let signedLength = Int(try capture("length: ([0-9]+)", in: xml))!
    try require(signedLength > 0 && signedLength < feed.count, "更新列表的签名长度无效")
    try require(String(decoding: feed.dropFirst(signedLength), as: UTF8.self).hasPrefix("<!-- sparkle-signatures:"), "更新列表存在未覆盖的内容")
    let signedFeed = Data(feed.prefix(signedLength))
    try require(key.isValidSignature(feedSignature, for: signedFeed), "更新列表签名无法用应用内公钥验证")
    let archiveSignature = Data(base64Encoded: try capture("sparkle:edSignature=\"([^\"]+)\"", in: xml))!
    let archiveLength = Int(try capture("<enclosure[^>]*length=\"([0-9]+)\"", in: xml))!
    try require(archive.count == archiveLength, "更新包大小与列表不一致")
    try require(key.isValidSignature(archiveSignature, for: archive), "更新包签名无法用应用内公钥验证")
    var tamperedFeed = signedFeed
    tamperedFeed[0] ^= 1
    try require(!key.isValidSignature(feedSignature, for: tamperedFeed), "篡改后的更新列表未被拒绝")
    var tamperedArchive = archive
    tamperedArchive[0] ^= 1
    try require(!key.isValidSignature(archiveSignature, for: tamperedArchive), "篡改后的安装包未被拒绝")
    print("update signature checks passed: shipped public key validates feed and ZIP; altered feed and ZIP are rejected")
} catch {
    fputs("update signature checks failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
