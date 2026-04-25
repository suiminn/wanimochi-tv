/*
 * StreamingEngine.swift - TRC firmware loading + TS streaming from EP1
 *
 * Handles: TRC FW upload → activate → EP1 bulk read → AES decrypt → deliver TS data.
 * Ported from gvm2tv-stream.c TRC loading and read_stream().
 */

import Foundation
import CommonCrypto

class StreamingEngine {
    private let client: DriverClient
    private let contentsKey: Data
    private var running = false
    private var readThread: Thread?

    /// Callback for delivering decrypted TS data chunks
    var onTSData: ((Data) -> Void)?

    /// Stats
    private(set) var totalBytes: UInt64 = 0
    private(set) var totalPackets: UInt64 = 0

    /// Fixed IV for AES decryption (from POC binary)
    private static let tsIVInit: [UInt8] = [
        0xec, 0x8f, 0x4b, 0x6a, 0xd9, 0x2a, 0x36, 0x89,
        0x2b, 0xdf, 0xb6, 0x18, 0xfc, 0x25, 0x5e, 0xfc
    ]

    /// TRC parameters (PID filter config)
    private static let trcParams: [(reg: UInt32, hi: UInt8, lo: UInt8)] = [
        (0x1002, 0x84, 0x04), (0x1004, 0x01, 0x84), (0x100a, 0x00, 0x20),
        (0x100c, 0x00, 0x10), (0x101a, 0xB3, 0x00), (0x101c, 0x02, 0x0F),
        (0x104c, 0x9F, 0xC8), (0x1050, 0x80, 0x10), (0x1052, 0x80, 0x11),
        (0x1054, 0x80, 0x12), (0x1056, 0x80, 0x14), (0x1058, 0x80, 0x24),
        (0x105a, 0x80, 0x27), (0x105c, 0x80, 0x29), (0x105e, 0x81, 0x00),
        (0x1060, 0x81, 0x10), (0x1062, 0x81, 0xF0), (0x1102, 0x00, 0x02),
        (0x1104, 0x61, 0xA8), (0x1136, 0x01, 0x41), (0x113a, 0x02, 0x0F),
    ]

    init(client: DriverClient, contentsKey: Data) {
        self.client = client
        self.contentsKey = contentsKey
    }

    // MARK: - TRC Firmware Loading

    func loadTRCFirmware(_ fwData: Data) throws {
        print("[TRC] Step 1: Clearing transcode param registers...")
        let zero: [UInt8] = [0x00, 0x00]
        var reg: UInt32 = 0x1000
        while reg < 0x1500 {
            try client.regWrite(reg: reg, data: zero)
            reg += 2
        }

        print("[TRC] Step 2: Setting transcode parameters...")
        for p in Self.trcParams {
            try client.regWrite(reg: p.reg, data: [p.hi, p.lo])
        }

        print("[TRC] Step 3: Enable firmware upload (cmd 0x04, 0x00)...")
        try client.sendApiCommand([0x00, 0x00, 0x04, 0x00, 0x00, 0x00])
        _ = try client.getAck(timeout: 1000)

        print("[TRC] Step 4: Uploading TRC firmware (\(fwData.count) bytes)...")
        try client.uploadFirmware(fwData)

        usleep(1000)

        print("[TRC] Step 5: Activate transcoder (cmd 0x04, 0x20)...")
        try client.sendApiCommand([0x00, 0x00, 0x04, 0x20, 0x00, 0x00])
        let activateAck = try client.getAck(timeout: 1000)
        print("[TRC] Activate ACK: \(activateAck.map { String(format: "%02x", $0) }.joined(separator: " "))")

        print("[TRC] Step 6: Waiting for state change...")
        for _ in 0..<20 {
            let msg = try client.getAck(timeout: 500)
            if !msg.isEmpty && msg[0] == 0x20 {
                print("[TRC] STATE_CHANGE received")
                break
            }
        }

        let state = try client.readDeviceState()
        print("[TRC] State after TRC: 0x\(String(format: "%04x", state))")

        print("[TRC] Firmware loading complete")
    }

    // MARK: - Start Streaming

    func start() throws {
        guard !running else { return }

        // Clear EP1 stall before starting
        print("[Stream] Clearing EP1 stall...")
        try? client.clearPipeStall(endpoint: 0x81)

        // Send START command
        print("[Stream] Sending START command...")
        try client.sendApiCommand([0x00, 0x00, 0x05, 0x00, 0x00, 0x02])
        let startAck = try client.getAck(timeout: 1000)
        print("[Stream] START ACK: \(startAck.map { String(format: "%02x", $0) }.joined(separator: " "))")

        // Brief wait for device to begin sending data
        usleep(100000)

        running = true
        totalBytes = 0
        totalPackets = 0

        // Start background read loop
        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.qualityOfService = .userInteractive
        readThread?.name = "TSStreamReader"
        readThread?.start()

        print("[Stream] Streaming started")
    }

    // MARK: - Stop Streaming

    func stop() {
        guard running else { return }
        running = false

        // Abort EP1 to unblock the blocking ReadPipe in readLoop
        try? client.abortPipe(endpoint: 0x81)

        // Wait for read thread to finish (up to 2 seconds)
        let deadline = Date().addingTimeInterval(2.0)
        while readThread != nil && !readThread!.isFinished && Date() < deadline {
            usleep(10000)
        }
        readThread = nil
        print("[Stream] Stopped. Total: \(totalBytes) bytes, \(totalPackets) packets")
    }

    // MARK: - Read Loop

    private func readLoop() {
        var tsBuf = Data()
        var outputBatch = Data()
        var logCounter = 0

        // Debug: save raw TS to file for analysis
        let debugPath = "/tmp/wanimochi_debug.ts"
        FileManager.default.createFile(atPath: debugPath, contents: nil)
        let debugFile = FileHandle(forWritingAtPath: debugPath)
        print("[Stream] Debug TS output: \(debugPath)")

        while running {
            do {
                let rawData = try client.bulkRead(length: 4096)
                if rawData.isEmpty {
                    usleep(1000)
                    continue
                }

                logCounter += 1
                if logCounter <= 5 || logCounter % 100 == 0 {
                    print("[Stream] EP1 read: \(rawData.count) bytes (total: \(totalBytes))")
                }

                tsBuf.append(contentsOf: rawData)

                // Process complete 188-byte TS packets
                var offset = 0
                while offset + 188 <= tsBuf.count {
                    if tsBuf[offset] != 0x47 {
                        offset += 1
                        continue
                    }

                    var packet = Data(tsBuf[offset..<offset + 188])
                    // Auto-detect encrypted PIDs from PMT
                    parsePMTIfNeeded(packet)
                    decryptPacket(&packet)
                    outputBatch.append(packet)
                    totalBytes += 188
                    totalPackets += 1
                    offset += 188
                }

                // Send batch to callback + debug file
                if !outputBatch.isEmpty {
                    debugFile?.write(outputBatch)
                    onTSData?(outputBatch)
                    outputBatch = Data()
                }

                // Keep leftover
                if offset > 0 {
                    tsBuf = Data(tsBuf[offset...])
                }

            } catch {
                if running {
                    print("[Stream] Read error: \(error)")
                    usleep(10000)
                }
            }
        }
    }

    // MARK: - AES Decrypt TS Packet

    /// PIDs that ARE encrypted by the device's AES layer (video + audio streams only).
    /// The device clears SC bits after AES encryption, so we can't use SC to detect.
    /// These PIDs come from the PMT for NHK (program 1024).
    private var encryptedPIDs: Set<UInt16> = [
        0x0100, // Video (MPEG2)
        0x0110, // Audio 1 (AAC)
        0x0111, // Audio 2 (AAC)
    ]

    private var pmtParsed = false

    /// Parse PMT to auto-detect video/audio ES PIDs
    private func parsePMTIfNeeded(_ packet: Data) {
        guard !pmtParsed else { return }
        guard packet.count >= 188, packet[0] == 0x47 else { return }

        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])
        let pusi = (packet[1] >> 6) & 1

        // PMT PID for program 1024 = 0x01F0
        guard pid == 0x01F0 && pusi == 1 else { return }

        let adapt = (packet[3] >> 4) & 3
        var off = 4
        if adapt == 3 { off += 1 + Int(packet[4]) }
        guard off < 188 else { return }

        off += Int(packet[off]) + 1 // pointer field
        guard off + 12 < 188 else { return }
        guard packet[off] == 0x02 else { return } // table_id = PMT

        let sectionLen = (Int(packet[off + 1] & 0x0F) << 8) | Int(packet[off + 2])
        let progInfoLen = (Int(packet[off + 10] & 0x0F) << 8) | Int(packet[off + 11])

        var esOff = off + 12 + progInfoLen
        let esEnd = off + 3 + sectionLen - 4 // exclude CRC
        var newPIDs: Set<UInt16> = []

        while esOff + 5 <= esEnd && esOff + 5 < 188 {
            let streamType = packet[esOff]
            let esPID = (UInt16(packet[esOff + 1] & 0x1F) << 8) | UInt16(packet[esOff + 2])
            let esInfoLen = (Int(packet[esOff + 3] & 0x0F) << 8) | Int(packet[esOff + 4])

            // Video (0x02=MPEG2, 0x1B=H.264) and Audio (0x0F=AAC, 0x11=AAC-LATM)
            if streamType == 0x02 || streamType == 0x1B || streamType == 0x0F || streamType == 0x11 {
                newPIDs.insert(esPID)
            }
            esOff += 5 + esInfoLen
        }

        if !newPIDs.isEmpty {
            encryptedPIDs = newPIDs
            pmtParsed = true
            print("[Stream] Auto-detected encrypted PIDs from PMT: \(newPIDs.map { String(format: "0x%04x", $0) })")
        }
    }

    private func decryptPacket(_ packet: inout Data) {
        guard packet.count >= 188, packet[0] == 0x47 else { return }

        // Check scrambling control bits (match C reference: sc != 0)
        let sc = (packet[3] >> 6) & 0x03
        guard sc != 0 else { return }

        let pid = (UInt16(packet[1] & 0x1F) << 8) | UInt16(packet[2])

        // Only decrypt known encrypted PIDs
        guard encryptedPIDs.contains(pid) else { return }

        let adapt = (packet[3] >> 4) & 0x03
        let payloadOff: Int
        switch adapt {
        case 0x02: return // adaptation only
        case 0x03: payloadOff = 5 + Int(packet[4])
        default:   payloadOff = 4
        }
        guard payloadOff < 188 else { return }

        let payloadLen = 188 - payloadOff
        if payloadLen < 16 { return } // Too short for AES

        let cbcLen = payloadLen & ~0x0F

        packet.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let payload = bytes.baseAddress! + payloadOff

            // Save last ciphertext block BEFORE CBC decrypt (needed for OFB IV)
            var lastCipherBlock = [UInt8](repeating: 0, count: 16)
            if cbcLen >= 16 {
                for i in 0..<16 {
                    lastCipherBlock[i] = payload[cbcLen - 16 + i]
                }
            }

            if cbcLen > 0 {
                var iv = Self.tsIVInit
                var tempOut = [UInt8](repeating: 0, count: cbcLen)
                contentsKey.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128), 0,
                            keyPtr.baseAddress, 16,
                            &iv,
                            payload, cbcLen,
                            &tempOut, cbcLen, nil)
                }
                memcpy(payload, &tempOut, cbcLen)
            }

            let ofbLen = payloadLen - cbcLen
            if ofbLen > 0 {
                // OFB IV = last ciphertext block from CBC (or ts_iv_init if no CBC)
                var ofbIV = cbcLen >= 16 ? lastCipherBlock : Self.tsIVInit
                var keystream = [UInt8](repeating: 0, count: 16)
                contentsKey.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            CCOptions(kCCOptionECBMode),
                            keyPtr.baseAddress, 16, nil,
                            &ofbIV, 16, &keystream, 16, nil)
                }
                for i in 0..<ofbLen {
                    payload[cbcLen + i] ^= keystream[i]
                }
            }
        }

        // Clear scrambling bits
        packet[3] &= 0x3F
    }
}
