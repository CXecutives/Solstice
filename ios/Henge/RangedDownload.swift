import CryptoKit
import Foundation

/// SHA-256 of a download as it arrives, kept across attempts: it covers the part file's first `bytes` bytes.
final class DownloadHash {
    private(set) var bytes: Int64 = 0
    private var hasher = SHA256()

    func reset() {
        hasher = SHA256()
        bytes = 0
    }

    func add(_ data: Data) {
        hasher.update(data: data)
        bytes += Int64(data.count)
    }

    /// Hashes what the part file holds past `bytes` (all of it after a reset), in 8 MB reads.
    func catchUp(with file: URL, to size: Int64) throws {
        if bytes > size { reset() }
        guard bytes < size else { return }
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(bytes))
        while bytes < size, let chunk = try h.read(upToCount: Int(min(8 << 20, size - bytes))), !chunk.isEmpty {
            add(chunk)
        }
    }

    /// The hex digest (the hasher goes on unchanged).
    var hex: String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}

/// Downloads `url` into the file `part`, appending: a download that stops for any reason (no network, Solstice
/// closed or killed) goes on from where the file ends the next time, with an HTTP range request (#58).
/// Apple's CDN answers ranges; a server that ignores one (200) starts the file again. Written in 8 MB pieces and
/// hashed as it arrives (`hash`); progress is said at most 4 times a second, not for every network packet.
final class RangedDownload: NSObject, URLSessionDataDelegate {
    let url: URL
    let part: URL
    let hash: DownloadHash
    /// Bytes in `part` and the whole file's size once known, on the delegate's queue, at most every progressEvery.
    private let progress: (Int64, Int64) -> Void
    private static let progressEvery: TimeInterval = 0.25
    private static let writeChunk = 8 << 20
    private var lastProgress = Date.distantPast
    private var handle: FileHandle?
    private var buffer = Data()
    private var have: Int64 = 0 /* received, written or in buffer */
    private var total: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?

    init(url: URL, part: URL, hash: DownloadHash, progress: @escaping (Int64, Int64) -> Void) {
        self.url = url
        self.part = part
        self.hash = hash
        self.progress = progress
    }

    /// Bytes already in a part file, or 0.
    static func size(of part: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// One attempt: fetches the rest of the file. Returns once `part` holds all of it; throws when this attempt
    /// stops early (what it wrote stays, for the next one).
    func run() async throws {
        if !FileManager.default.fileExists(atPath: part.path) {
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else {
                throw NSError(domain: "Solstice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Solstice couldn't create the download file."])
            }
        }
        have = Self.size(of: part)
        try hash.catchUp(with: part, to: have) // what an earlier launch (or a cut-short write) left
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 48 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        session = s
        defer { s.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = c
                    let t = s.dataTask(with: request)
                    self.task = t
                    t.resume()
                }
            }
        } onCancel: {
            queue.addOperation { self.task?.cancel() }
        }
    }

    /// Stops the attempt in progress (what was written stays).
    func cancel() { task?.cancel() }

    /// The buffer to the file. False (and failure set) if it could not be written.
    @discardableResult
    private func flush() -> Bool {
        guard let h = handle, !buffer.isEmpty else { return true }
        do {
            try h.write(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
            return true
        } catch {
            failure = failure ?? error
            return false
        }
    }

    private func finish(_ error: Error?) {
        let written = flush()
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        progress(have, total)
        guard let c = continuation else { return }
        continuation = nil
        if let error { c.resume(throwing: error) } else if !written, let failure { c.resume(throwing: failure) } else { c.resume() }
    }

    private func report(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastProgress) >= Self.progressEvery else { return }
        lastProgress = now
        progress(have, total)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        do {
            switch status {
            case 206: // the rest, from where the file ends: "bytes start-end/total"
                let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
                let start = Int64(range.split(separator: " ").last?.split(separator: "-").first ?? "") ?? -1
                total = Int64(range.split(separator: "/").last ?? "") ?? 0
                guard start == have else {
                    throw NSError(domain: "Solstice", code: 5, userInfo: [NSLocalizedDescriptionKey: "Apple's server sent the wrong part of the file."])
                }
            case 200: // the whole file: start again
                total = response.expectedContentLength
                have = 0
                hash.reset()
            case 416: // nothing past where the file ends: it is complete (servers don't always say the size here)
                let range = http?.value(forHTTPHeaderField: "Content-Range") ?? ""
                total = Int64(range.split(separator: "/").last ?? "") ?? 0
                if total > 0 && have > total, let h = try? FileHandle(forWritingTo: part) {
                    try? h.truncate(atOffset: UInt64(total))
                    try? h.close()
                    have = total
                    hash.reset()
                    try? hash.catchUp(with: part, to: have)
                }
                if total == 0 { total = have }
                completionHandler(.cancel)
                finish(nil)
                return
            default:
                throw NSError(domain: "Solstice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Apple's server answered \(status)."])
            }
            let h = try FileHandle(forWritingTo: part)
            try h.truncate(atOffset: UInt64(have))
            try h.seekToEnd()
            handle = h
            buffer.reserveCapacity(Self.writeChunk + (1 << 20))
            report(force: true)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard handle != nil else { return }
        buffer.append(data)
        hash.add(data)
        have += Int64(data.count)
        if buffer.count >= Self.writeChunk && !flush() {
            dataTask.cancel()
            return
        }
        report()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if continuation == nil { return } // already finished (416 with a complete file)
        if let failure { finish(failure); return }
        if let error { finish(error); return }
        if total > 0 && have != total {
            finish(NSError(domain: "Solstice", code: 7, userInfo: [NSLocalizedDescriptionKey: "The download ended early (\(have) of \(total) bytes)."]))
            return
        }
        finish(nil)
    }
}
