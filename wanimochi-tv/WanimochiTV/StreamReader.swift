/*
 * StreamReader.swift - Shared memory ring buffer reader
 *
 * Reads TS data from the DEXT's shared memory ring buffer and passes
 * it through the TSDecryptor before delivering to the video pipeline.
 */

import Foundation

class StreamReader {
    private let ringBufferAddress: UnsafeMutableRawPointer
    private let ringBufferSize: Int
    private var running = false
    private var readThread: Thread?

    /// Callback invoked with decrypted TS data chunks
    var onData: ((Data) -> Void)?

    /// TSDecryptor for AES decryption (set when Contents Key is available)
    var decryptor: TSDecryptor?

    init(ringBufferAddress: UnsafeMutableRawPointer, ringBufferSize: Int) {
        self.ringBufferAddress = ringBufferAddress
        self.ringBufferSize = ringBufferSize
    }

    func start() {
        guard !running else { return }
        running = true

        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.qualityOfService = .userInteractive
        readThread?.start()
    }

    func stop() {
        running = false
        readThread = nil
    }

    private func readLoop() {
        let headerSize = 64 // GVM2TV_RING_BUFFER_HEADER_SIZE
        let header = ringBufferAddress.bindMemory(to: UInt64.self, capacity: 8)
        let dataArea = ringBufferAddress + headerSize
        let dataSize = UInt64(ringBufferSize - headerSize)

        while running {
            // Read write offset atomically
            let writeOff = header[0] // writeOffset at offset 0
            let readOff = header[1]  // readOffset at offset 8

            if writeOff == readOff {
                // No data available, sleep briefly
                usleep(1000) // 1ms
                continue
            }

            // Calculate available data
            let available: UInt64
            if writeOff > readOff {
                available = writeOff - readOff
            } else {
                available = dataSize - readOff + writeOff
            }

            guard available > 0 else { continue }

            // Read data from ring buffer
            let readLen = min(available, 4096)
            var chunk = Data(count: Int(readLen))

            chunk.withUnsafeMutableBytes { buf in
                let src = dataArea.assumingMemoryBound(to: UInt8.self)
                var remaining = Int(readLen)
                var srcOffset = Int(readOff)
                var dstOffset = 0

                while remaining > 0 {
                    let firstPart = min(remaining, Int(dataSize) - srcOffset)
                    memcpy(buf.baseAddress! + dstOffset, src + srcOffset, firstPart)
                    dstOffset += firstPart
                    remaining -= firstPart
                    srcOffset = 0 // Wrap around
                }
            }

            // Update read offset
            let newReadOff = (readOff + readLen) % dataSize
            header[1] = newReadOff

            // Decrypt if decryptor available
            if let decryptor = decryptor {
                let decrypted = decryptor.decryptBuffer(chunk)
                onData?(decrypted)
            } else {
                onData?(chunk)
            }
        }
    }
}
