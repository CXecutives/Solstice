import CryptoKit
import Foundation

/// RangedDownload: which failures another attempt can cure (the network) and which not (a full storage, a part file
/// that cannot be written), and the hash catching up with a part file by reading only what it has not seen.
@main
struct RangedDownloadTests {
    static func main() throws {
        let enospc = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        precondition(RangedDownload.storageFull(enospc), "ENOSPC is storage full")
        precondition(RangedDownload.storageFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EDQUOT))), "a quota is storage full")
        // FileHandle's write says it as a Cocoa error, with the POSIX one beneath.
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: [NSUnderlyingErrorKey: enospc])
        precondition(RangedDownload.storageFull(cocoa), "out of space is storage full")
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: enospc])
        precondition(RangedDownload.storageFull(wrapped), "ENOSPC beneath another error is storage full")
        precondition(RangedDownload.storageFull(WriteFailed(underlying: cocoa)), "a failed write of a full storage")
        precondition(!RangedDownload.retryable(WriteFailed(underlying: cocoa)), "a full storage: no retry")
        precondition(!RangedDownload.retryable(enospc), "ENOSPC: no retry")

        let eio = WriteFailed(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        precondition(!RangedDownload.storageFull(eio), "EIO is not storage full")
        precondition(!RangedDownload.retryable(eio), "a write that fails: no retry")

        precondition(RangedDownload.retryable(URLError(.timedOut)), "a timeout: retry")
        precondition(RangedDownload.retryable(URLError(.networkConnectionLost)), "a lost connection: retry")
        precondition(!RangedDownload.storageFull(URLError(.timedOut)), "a timeout is not storage full")
        precondition(RangedDownload.retryable(NSError(domain: "Solstice", code: 7)), "ended early: retry")

        // The hash covers what it was given, then reads only the rest of the file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ranged-\(getpid()).part")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try bytes.write(to: file)
        let whole = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let hash = DownloadHash()
        hash.add(bytes.prefix(60_000))
        try hash.catchUp(with: file, to: Int64(bytes.count))
        precondition(hash.bytes == Int64(bytes.count) && hash.hex == whole, "caught up from where it was")
        try hash.catchUp(with: file, to: Int64(bytes.count))
        precondition(hash.bytes == Int64(bytes.count) && hash.hex == whole, "caught up already: nothing read")
        print("ranged download ok")
    }
}
