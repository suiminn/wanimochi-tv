/*
 * DirectTSStreamSink.swift - direct decrypted TS handoff for VLCKit
 */

import Darwin
import Foundation

final class DirectTSStreamSink {
    private let lock = NSLock()
    private let pipeURL: URL
    private var writerFD: Int32 = -1
    private var isPrepared = false

    init(channel: Int) {
        let filename = "wanimochi_tv_ch\(channel)_\(UUID().uuidString).ts"
        pipeURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(filename)
    }

    func prepare() throws -> URL {
        signal(SIGPIPE, SIG_IGN)

        let path = pipeURL.path
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(at: pipeURL)
        }

        guard mkfifo(path, mode_t(0o600)) == 0 else {
            throw DirectTSStreamError.operationFailed("mkfifo", path: path, errnoCode: errno)
        }

        lock.lock()
        isPrepared = true
        lock.unlock()

        return pipeURL
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard isPrepared else { return }

        if writerFD < 0 {
            writerFD = Darwin.open(pipeURL.path, O_WRONLY | O_NONBLOCK)
            if writerFD < 0 {
                return
            }
        }

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }

            let packetSize = 188
            var offset = 0
            while offset < data.count {
                let writeLength = min(packetSize, data.count - offset)
                let result = Darwin.write(
                    writerFD,
                    baseAddress.advanced(by: offset),
                    writeLength
                )

                if result == writeLength {
                    offset += writeLength
                    continue
                }

                if result < 0 && errno == EINTR {
                    continue
                }

                if result < 0 && (errno == EPIPE || errno == EBADF) {
                    closeWriterLocked()
                }
                break
            }
        }
    }

    func close() {
        lock.lock()
        isPrepared = false
        closeWriterLocked()
        let url = pipeURL
        lock.unlock()

        try? FileManager.default.removeItem(at: url)
    }

    deinit {
        close()
    }

    private func closeWriterLocked() {
        if writerFD >= 0 {
            Darwin.close(writerFD)
            writerFD = -1
        }
    }
}

private enum DirectTSStreamError: LocalizedError {
    case operationFailed(String, path: String, errnoCode: Int32)

    var errorDescription: String? {
        switch self {
        case let .operationFailed(operation, path, errnoCode):
            let message = String(cString: strerror(errnoCode))
            return "\(operation) failed for \(path): \(message)"
        }
    }
}
