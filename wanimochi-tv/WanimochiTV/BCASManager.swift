/*
 * BCASManager.swift - B-CAS card initialization and ECM processing
 *
 * Manages B-CAS card communication via the DEXT's register relay.
 * Handles card init, INT/IDI APDU commands, and retainSecureEP.
 *
 * Ported from gvm2tv-stream.c setup_bcas() and gvm2tv-init.c B-CAS code.
 */

import Foundation
import CommonCrypto

class BCASManager {
    private let client: DriverClient
    private let aesKey: Data
    var secureAuth: SecureAuth?

    /// B-CAS initialization data
    private(set) var systemKey: Data?
    private(set) var initCBC: Data?
    private(set) var cardId: Int64 = 0
    private(set) var contentsKey: Data?

    init(client: DriverClient, aesKey: Data) {
        self.client = client
        self.aesKey = aesKey
    }

    // MARK: - Full B-CAS Initialization

    func initialize() throws {
        // Step 1: Reset B-CAS reader
        _ = try client.sendApiCommand(Data([0x00, 0x00, 0x0A, 0x00, 0x00, 0x01]))
        _ = try? client.getInterruptMessage(timeout: 2000)

        // Step 2: Init B-CAS card
        _ = try client.sendApiCommand(Data([0x00, 0x00, 0x0A, 0x01, 0x00, 0x01]))
        _ = try? client.getInterruptMessage(timeout: 2000)

        // Step 3: Wait for B-CAS ready (poll 0x822AC)
        try waitBCASReady()

        // Step 4: INT command (Initial Setting)
        try sendBCASCommand(apdu: Data([0x90, 0x30, 0x00, 0x00, 0x00]))
        usleep(50000) // 50ms

        let intResp = try getBCASResponse()
        if intResp.count >= 50 {
            systemKey = Data(intResp[10..<42])
            initCBC = Data(intResp[42..<50])
            if intResp.count >= 58 {
                var id: Int64 = 0
                for i in 0..<8 {
                    id = (id << 8) | Int64(intResp[50 + i])
                }
                cardId = id
            }
        }

        // Step 5: IDI command (ID Information)
        try sendBCASCommand(apdu: Data([0x90, 0x32, 0x00, 0x00, 0x00]))
        usleep(50000)
        _ = try? getBCASResponse()

        // Step 6: retainSecureEP (get Contents Key)
        try retainSecureEP()
    }

    // MARK: - Individual Steps (called by DeviceController)

    func sendINTCommand() throws {
        try sendBCASCommand(apdu: Data([0x90, 0x30, 0x00, 0x00, 0x00]))
        usleep(50000)

        let intResp = try getBCASResponse()
        print("[BCAS] INT response: \(intResp.count) bytes")
        if intResp.count >= 50 {
            systemKey = Data(intResp[10..<42])
            initCBC = Data(intResp[42..<50])
            print("[BCAS] System key: \(systemKey!.map { String(format: "%02x", $0) }.joined())")
            print("[BCAS] CBC init: \(initCBC!.map { String(format: "%02x", $0) }.joined())")
            if intResp.count >= 58 {
                var id: Int64 = 0
                for i in 0..<8 {
                    id = (id << 8) | Int64(intResp[50 + i])
                }
                cardId = id
                print("[BCAS] Card ID: \(cardId)")
            }
        }
    }

    func sendIDICommand() throws {
        try sendBCASCommand(apdu: Data([0x90, 0x32, 0x00, 0x00, 0x00]))
        usleep(50000)
        let idiResp = try? getBCASResponse()
        print("[BCAS] IDI response: \(idiResp?.count ?? 0) bytes")
    }

    // MARK: - ECM Processing

    func processECM(ecmBody: Data) throws -> (oddKey: Data, evenKey: Data)? {
        // Build APDU: 90 34 00 00 <len> <data> 00
        var apdu = Data([0x90, 0x34, 0x00, 0x00, UInt8(ecmBody.count)])
        apdu.append(ecmBody)
        apdu.append(0x00)

        try sendBCASCommand(apdu: apdu)
        usleep(50000)

        let resp = try getBCASResponse()
        guard resp.count >= 26 else { return nil }

        let oddKey = Data(resp[10..<18])
        let evenKey = Data(resp[18..<26])
        return (oddKey, evenKey)
    }

    // MARK: - B-CAS Protocol

    private func sendBCASCommand(apdu: Data) throws {
        var buf = Data(count: 0x110)

        // Header
        buf[0] = 0xFF; buf[1] = 0x00
        buf[2] = 0xFF; buf[3] = 0x00

        // Copy APDU with per-word byte swap
        for i in stride(from: 0, to: apdu.count, by: 2) {
            if i + 1 < apdu.count {
                buf[4 + i] = apdu[i + 1]
                buf[4 + i + 1] = apdu[i]
            } else {
                buf[4 + i] = 0x00
                buf[4 + i + 1] = apdu[i]
            }
        }

        var totalLen = apdu.count + 4
        if totalLen & 1 != 0 { totalLen += 1 }

        // AES encrypt
        let encLen = (totalLen + 15) & ~15

        // Step 1: byte-swap enc_len words
        var temp = Data(count: 0x110)
        for i in 0..<encLen {
            temp[i * 2] = buf[i * 2 + 1]
            temp[i * 2 + 1] = buf[i * 2]
        }

        // Step 2: AES-CBC encrypt enc_len bytes
        var cipher = Data(count: 0x110)
        var iv = Data(count: 16)
        _ = cipher.withUnsafeMutableBytes { cipherPtr in
            temp.withUnsafeBytes { tempPtr in
                iv.withUnsafeMutableBytes { ivPtr in
                    aesKey.withUnsafeBytes { keyPtr in
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES128), 0,
                                keyPtr.baseAddress, 16,
                                ivPtr.baseAddress,
                                tempPtr.baseAddress, encLen,
                                cipherPtr.baseAddress, 0x110,
                                nil)
                    }
                }
            }
        }

        // Step 3: copy cipher → temp
        temp.replaceSubrange(0..<encLen, with: cipher.prefix(encLen))

        // Step 4: byte-swap 136 words temp → buf
        for i in 0..<0x88 {
            buf[i * 2] = temp[i * 2 + 1]
            buf[i * 2 + 1] = temp[i * 2]
        }

        // Step 5: rolw enc_len words
        swap16Buf(&buf, count: encLen * 2)

        // Step 6: write to 0x8219C
        try client.bcasRegWrite(reg: 0x8219C, data: buf.prefix(encLen))

        // Send API command
        let cmdSize = (apdu.count + 4 + 1) & ~1
        let cmd = Data([0x00, 0x00, 0x0A, 0x10,
                        UInt8((cmdSize >> 8) & 0xFF), UInt8(cmdSize & 0xFF)])
        _ = try client.sendApiCommand(cmd)
        _ = try? client.getInterruptMessage(timeout: 3000)
    }

    private func getBCASResponse() throws -> Data {
        // Poll 0x822AC for ready
        for _ in 0..<30 {
            let st = try client.bcasRegRead(reg: 0x822AC, length: 2)
            let nibble = (st[0] >> 4) & 0x0F
            if nibble == 3 { break }
            if nibble != 2 { throw GVM2TVError.bcasError("unexpected state") }
            usleep(20000)
        }

        // Read response length
        let st = try client.bcasRegRead(reg: 0x822AC, length: 2)
        var respLen = (Int(st[0] & 0x0F) << 8) | Int(st[1])
        if respLen <= 0 || respLen > 512 { respLen = 256 }
        if respLen < 16 { respLen = 16 }
        let encLen = (respLen + 15) & ~15

        // Read response from 0x822AE
        let raw = try client.bcasRegRead(reg: 0x822AE, length: encLen)

        // AES-CBC decrypt
        var plain = Data(count: encLen)
        var iv = Data(count: 16)
        _ = plain.withUnsafeMutableBytes { plainPtr in
            raw.withUnsafeBytes { rawPtr in
                iv.withUnsafeMutableBytes { ivPtr in
                    aesKey.withUnsafeBytes { keyPtr in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES128), 0,
                                keyPtr.baseAddress, 16,
                                ivPtr.baseAddress,
                                rawPtr.baseAddress, encLen,
                                plainPtr.baseAddress, encLen,
                                nil)
                    }
                }
            }
        }

        // Remove 4-byte header if present
        if plain.count >= 4 && plain[0] == 0xFF && plain[1] == 0x00
            && plain[2] == 0xFF && plain[3] == 0x00 {
            return Data(plain.dropFirst(4))
        }
        return plain
    }

    func retainSecureEP() throws {
        guard let auth = secureAuth else {
            throw GVM2TVError.bcasError("SecureAuth not set")
        }

        let cmdId: UInt32 = 0x07010600
        // Build params: [0x03000000, 0x00000000, 0x00000000]
        var params = Data(count: 12)
        params[0] = 0x00; params[1] = 0x00  // lo word of 0x03000000
        params[2] = 0x00; params[3] = 0x03  // hi word
        // params[4..11] = 0 (already zero)

        let input = auth.buildSecureCmd(cmdId: cmdId, paramCount: 3, params: params)
        let output = try auth.sendSecureCommand(cmdId: cmdId, input: input)

        // Extract Contents Key from decoded response at offset 16
        contentsKey = Data(output[16..<32])
        print("[BCAS] retainSecureEP decoded resp[0..32]: \(output[0..<32].map { String(format: "%02x", $0) }.joined())")
        print("[BCAS] Contents Key: \(contentsKey!.map { String(format: "%02x", $0) }.joined())")
    }

    private func waitBCASReady() throws {
        for _ in 0..<20 {
            let st = try client.bcasRegRead(reg: 0x822AC, length: 2)
            let nibble = (st[0] >> 4) & 0x0F
            if nibble == 3 { return }
            if nibble != 2 { break }
            usleep(20000)
        }
    }

    private func swap16Buf(_ data: inout Data, count: Int) {
        let len = min(count, data.count)
        data.withUnsafeMutableBytes { ptr in
            let bytes = ptr.bindMemory(to: UInt8.self)
            var i = 0
            while i < len - 1 {
                let tmp = bytes[i]
                bytes[i] = bytes[i + 1]
                bytes[i + 1] = tmp
                i += 2
            }
        }
    }
}
