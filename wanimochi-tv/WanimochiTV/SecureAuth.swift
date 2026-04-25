/*
 * SecureAuth.swift - Certificate authentication for GV-M2TV
 *
 * Performs the DRV_CER_START → DRV_CER_RES_SEND flow using CommonCrypto
 * instead of OpenSSL. Communicates with the device via DriverClient.
 *
 * Ported from gvm2tv-init.c do_certificate() function.
 */

import Foundation
import CommonCrypto

class SecureAuth {
    private let client: DriverClient

    /// AES-128 key derived from certificate authentication
    private(set) var aesKey: Data?

    init(client: DriverClient) {
        self.client = client
    }

    // MARK: - Public

    /// Perform full certificate authentication. Returns the derived AES key.
    func performAuthentication() throws -> Data {
        // Enable secure interrupts
        try client.regWrite(reg: 0x90078, data: [0x08, 0x04])

        // Step 1: DRV_CER_START
        let cerStartInput = buildSecureCmd(cmdId: 0x01010000, paramCount: 8,
                                           params: Data(Self.driverVersion))
        let cerStartResp = try sendSecureCommand(cmdId: 0x01010000, input: cerStartInput)
        let decoded = decodeSecureResponse(wire: cerStartResp, expectedCmdId: 0x01010000)

        // Extract secure_version from decoded[0x27]
        let secureVersion = decoded[0x27]

        // Step 2: Derive password index
        var shaInput = Data(Self.magicNumber)
        shaInput.append(secureVersion)
        shaInput.append(0x0B)
        let shaResult = sha1(shaInput)
        let pwdIndex = Int(shaResult[19]) & 0x0F

        // Step 3: Build challenge
        var challenge = bswap32Buf(Data(decoded[4..<36]))
        challenge.append(bswap32Buf(Data(Self.driverPasswordList[pwdIndex])))

        let challengeHash = sha1(challenge)

        // Step 4: DRV_CER_RES_SEND
        let cerResInput = buildSecureCmd(cmdId: 0x01020000, paramCount: 5,
                                         params: challengeHash)
        _ = try sendSecureCommand(cmdId: 0x01020000, input: cerResInput)

        // Step 5: Derive AES key
        var sha3Input = challengeHash
        sha3Input.append(bswap32Buf(Data(Self.driverPasswordList[pwdIndex])))
        let sha3 = sha1(sha3Input)

        var key = Data(count: 16)
        key[0..<4] = sha3[16..<20]
        key[4..<8] = sha3[6..<10]
        key[8..<12] = sha3[11..<15]
        key[12..<16] = sha3[0..<4]

        aesKey = key
        return key
    }

    // MARK: - Secure Command Protocol

    func buildSecureCmd(cmdId: UInt32, paramCount: UInt32, params: Data) -> Data {
        var buf = Data(count: 512)

        // cmd_id: split into high word (LE) at [0:2], low word (LE) at [2:4]
        buf[0] = UInt8((cmdId >> 16) & 0xFF)
        buf[1] = UInt8((cmdId >> 24) & 0xFF)
        buf[2] = UInt8(cmdId & 0xFF)
        buf[3] = UInt8((cmdId >> 8) & 0xFF)

        // param_count: split
        buf[8] = UInt8((paramCount >> 16) & 0xFF)
        buf[9] = UInt8((paramCount >> 24) & 0xFF)
        buf[10] = UInt8(paramCount & 0xFF)
        buf[11] = UInt8((paramCount >> 8) & 0xFF)

        // 0xFFFFFFFF separator
        buf[12] = 0xFF; buf[13] = 0xFF; buf[14] = 0xFF; buf[15] = 0xFF

        // Parameter data
        let copyLen = min(params.count, 496)
        buf.replaceSubrange(16..<(16 + copyLen), with: params.prefix(copyLen))

        return buf
    }

    /// Public so BCASManager can reuse for retainSecureEP
    func sendSecureCommand(cmdId: UInt32, input: Data) throws -> Data {
        var buf = input

        if cmdId & 0x400 != 0 {
            // Encrypted command path
            guard let key = aesKey else {
                throw GVM2TVError.authenticationFailed
            }

            var plain = Data(buf[12..<508])
            var cipher = Data(count: 496)
            var iv = Data(count: 16)
            _ = cipher.withUnsafeMutableBytes { cipherPtr in
                plain.withUnsafeBytes { plainPtr in
                    iv.withUnsafeMutableBytes { ivPtr in
                        key.withUnsafeBytes { keyPtr in
                            CCCrypt(CCOperation(kCCEncrypt),
                                    CCAlgorithm(kCCAlgorithmAES128),
                                    0, // No padding (data is already aligned)
                                    keyPtr.baseAddress, 16,
                                    ivPtr.baseAddress,
                                    plainPtr.baseAddress, 496,
                                    cipherPtr.baseAddress, 496,
                                    nil)
                        }
                    }
                }
            }

            // Copy back with byte-swap within 16-bit words
            for i in 0..<248 {
                buf[12 + i * 2 + 0] = cipher[i * 2 + 1]
                buf[12 + i * 2 + 1] = cipher[i * 2 + 0]
            }

            swap16Buf(&buf, count: 510)
        } else {
            // Header-only swap (12 bytes)
            swap16Buf(&buf, count: 12)
        }

        // Write 512 bytes in 8x64B chunks to 0x83000
        try client.secureRegWrite(baseReg: 0x83000, data: buf)

        // Trigger: SetApiCmd 0x08
        _ = try client.sendApiCommand(Data([0x00, 0x00, 0x08, 0x00, 0x00, 0x00]))

        // Wait for ACK
        var gotAck = false
        for _ in 0..<20 {
            do {
                let ack = try client.getInterruptMessage(timeout: 500)
                if !ack.isEmpty {
                    gotAck = true
                    break
                }
            } catch {
                continue
            }
        }
        if !gotAck {
            print("WARNING: No ACK received for secure command")
        }

        // Read 512-byte response
        var output = try client.secureRegRead(baseReg: 0x83000, length: 512)

        // Apply full swap to response
        swap16Buf(&output, count: 510)

        // Decrypt response if encrypted command
        if cmdId & 0x400 != 0, let key = aesKey {
            var cipherResp = Data(count: 496)
            for i in 0..<248 {
                cipherResp[i * 2 + 0] = output[12 + i * 2 + 1]
                cipherResp[i * 2 + 1] = output[12 + i * 2 + 0]
            }

            var plainResp = Data(count: 496)
            var iv = Data(count: 16)
            _ = plainResp.withUnsafeMutableBytes { plainPtr in
                cipherResp.withUnsafeBytes { cipherPtr in
                    iv.withUnsafeMutableBytes { ivPtr in
                        key.withUnsafeBytes { keyPtr in
                            CCCrypt(CCOperation(kCCDecrypt),
                                    CCAlgorithm(kCCAlgorithmAES128),
                                    0,
                                    keyPtr.baseAddress, 16,
                                    ivPtr.baseAddress,
                                    cipherPtr.baseAddress, 496,
                                    plainPtr.baseAddress, 496,
                                    nil)
                        }
                    }
                }
            }

            output.replaceSubrange(12..<508, with: plainResp)
        }

        return output
    }

    private func decodeSecureResponse(wire: Data, expectedCmdId: UInt32) -> Data {
        func wireDword(_ off: Int) -> UInt32 {
            let lo = UInt32(wire[off]) | (UInt32(wire[off + 1]) << 8)
            let hi = UInt32(wire[off + 2]) | (UInt32(wire[off + 3]) << 8)
            return (lo << 16) | hi
        }

        let paramCount = wireDword(8)

        var decoded = Data(count: 256)
        let status = wireDword(4)
        decoded[0] = UInt8(status & 0xFF)
        decoded[1] = UInt8((status >> 8) & 0xFF)
        decoded[2] = UInt8((status >> 16) & 0xFF)
        decoded[3] = UInt8((status >> 24) & 0xFF)

        for i in 0..<Int(paramCount) {
            guard 4 + i * 4 + 4 <= decoded.count else { break }
            let d = wireDword(16 + i * 4)
            let off = 4 + i * 4
            decoded[off + 0] = UInt8(d & 0xFF)
            decoded[off + 1] = UInt8((d >> 8) & 0xFF)
            decoded[off + 2] = UInt8((d >> 16) & 0xFF)
            decoded[off + 3] = UInt8((d >> 24) & 0xFF)
        }

        return decoded
    }

    // MARK: - Crypto Helpers

    private func sha1(_ data: Data) -> Data {
        var digest = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { dataPtr in
            digest.withUnsafeMutableBytes { digestPtr in
                _ = CC_SHA1(dataPtr.baseAddress, CC_LONG(data.count),
                           digestPtr.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return digest
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

    private func bswap32Buf(_ src: Data) -> Data {
        var dst = Data(count: src.count)
        for i in stride(from: 0, to: src.count - 3, by: 4) {
            dst[i + 0] = src[i + 3]
            dst[i + 1] = src[i + 2]
            dst[i + 2] = src[i + 1]
            dst[i + 3] = src[i + 0]
        }
        return dst
    }

    // MARK: - Hardcoded Constants (from m2TV app binary)

    private static let driverVersion: [UInt8] = [
        0x15, 0x00, 0x95, 0xf8, 0xc5, 0x08, 0x43, 0xa5,
        0xa9, 0x45, 0xf2, 0x5b, 0x63, 0x73, 0x3e, 0x0b,
        0x36, 0x42, 0x63, 0x09, 0x4a, 0x1d, 0x4e, 0x9e,
        0x9a, 0x33, 0x95, 0xf8, 0xc5, 0x08, 0xa2, 0x52
    ]

    private static let magicNumber: [UInt8] = [
        0xc2, 0x94, 0xa1, 0xbd, 0x41, 0xa9, 0xe3, 0x8e,
        0xf3, 0x5b, 0xa1, 0x83, 0x6b, 0x93, 0xda, 0x6c,
        0xd9, 0x5a, 0x1f, 0x24, 0x8b, 0xa9, 0x3d, 0x6b,
        0x39, 0xd2, 0xa3, 0x6b
    ]

    private static let driverPasswordList: [[UInt8]] = [
        [0x25,0x59,0xd4,0x29,0xc2,0xfb,0xbf,0xd2,0x30,0x93,0x01,0x71,0x2f,0x89,0x01,0xed,
         0x8e,0x94,0xb0,0xf3,0x4e,0x1f,0xb8,0x27,0x83,0xd9,0x1b,0xe2,0xb8,0x98,0xa0,0xd1],
        [0x9e,0x4e,0xd3,0x72,0x51,0x03,0x3c,0x64,0xd6,0xb1,0x1a,0xc8,0x86,0xf7,0xc8,0xaa,
         0x4b,0x3e,0xdd,0xa5,0x0e,0x87,0x5a,0xc0,0x6c,0xc2,0x3d,0xd1,0x05,0x53,0xe1,0x04],
        [0x7d,0xde,0x0c,0xe5,0xa0,0x35,0x1b,0x3b,0x15,0x92,0x17,0xe1,0xb4,0x60,0xc3,0x46,
         0x59,0x8d,0xd5,0x4c,0xf9,0x10,0x47,0xb0,0x59,0x94,0x9c,0xd0,0xfc,0xa5,0x95,0x60],
        [0xf6,0xbe,0x41,0xe6,0x6c,0xa1,0x20,0x36,0x70,0x45,0xd2,0xe0,0x07,0x4b,0x3d,0x54,
         0x08,0x13,0x47,0x1d,0xda,0x18,0x3f,0x8e,0xb4,0x4b,0xd7,0x97,0xe5,0x89,0x8b,0x0d],
        [0xf5,0x5b,0x71,0x26,0x82,0xa0,0xec,0x53,0x4d,0x34,0x77,0x2e,0x34,0xda,0x1e,0x59,
         0x2e,0xda,0xa5,0xca,0xb8,0xf1,0xd5,0x10,0x42,0xf2,0x25,0x56,0x08,0x87,0x45,0x46],
        [0x5c,0x30,0xf9,0xf5,0xb3,0xd9,0x1c,0x26,0x8f,0xc0,0x3b,0x55,0x9e,0x79,0xb6,0x05,
         0x97,0x86,0x47,0x3b,0x6f,0xa3,0xe1,0x7c,0x7e,0xd5,0xcd,0x0d,0xa1,0x50,0x2f,0xe3],
        [0x7d,0xed,0x56,0x9c,0xf8,0xc2,0x82,0x9f,0x49,0x21,0x1d,0xd0,0xe3,0x0a,0x8b,0x09,
         0x93,0xc9,0x6d,0x1b,0xfe,0x0d,0x14,0x66,0x7f,0x2b,0x01,0x74,0x3f,0xbf,0xcb,0x7c],
        [0x7d,0xba,0xd7,0xa2,0x0c,0x58,0xbf,0xb7,0x5e,0x48,0x8f,0xb0,0x24,0xea,0x07,0x33,
         0x90,0xd5,0x7f,0x69,0xad,0xd5,0x9f,0x28,0xf8,0x22,0xa7,0x7b,0x79,0xc5,0x02,0xde],
        [0x9b,0xdb,0x72,0xb2,0x6d,0x24,0x1f,0x5c,0xa8,0xd6,0xa8,0x07,0xdb,0x46,0x18,0x6b,
         0x7a,0xa5,0x2f,0x45,0xc0,0xaa,0x23,0xc0,0xd6,0x01,0xa5,0xb0,0x0b,0x75,0x25,0x64],
        [0x47,0x28,0x44,0xe0,0x21,0x87,0xc0,0x1b,0x4d,0x96,0x24,0x40,0x77,0x6f,0xe3,0xf1,
         0xc3,0xbc,0xad,0x06,0x2d,0xb2,0xc5,0x65,0x5f,0x54,0xdd,0x11,0x4a,0x2d,0x08,0xe4],
        [0x79,0x0c,0x4f,0x02,0x1e,0x59,0xd4,0xf9,0x07,0x3d,0xd8,0x93,0xc0,0x26,0x91,0xbf,
         0x06,0xcd,0xd3,0x7f,0x21,0xb3,0x67,0xe3,0x50,0xc2,0x58,0x69,0x43,0x16,0xad,0x50],
        [0x2e,0x1c,0x82,0x8e,0xdd,0x2f,0xb5,0x9c,0x83,0xb7,0x5c,0x3e,0x2a,0x4b,0x08,0xf6,
         0x09,0x69,0x0f,0x82,0x80,0xd2,0x9d,0x24,0x2a,0xbd,0xa3,0x75,0xa7,0x3f,0x6d,0x11],
        [0xb7,0xb6,0xe6,0x35,0x71,0xea,0x21,0xae,0x8b,0xc3,0xd9,0x7c,0x23,0xcc,0xa6,0x55,
         0x8a,0xef,0x34,0x0e,0x5f,0xec,0x49,0x0c,0x38,0xb5,0x58,0xb8,0x7e,0xa8,0x7e,0xe4],
        [0xe1,0x69,0xbf,0x62,0xfe,0xa7,0xee,0x5f,0xf9,0x9c,0xb6,0x82,0x78,0x9d,0x5d,0x03,
         0x72,0xf8,0xf3,0xd6,0x9a,0xc8,0x65,0x67,0xc0,0x19,0xf7,0xe7,0xa9,0x1e,0x92,0x4c],
        [0xf9,0x2d,0x71,0x0c,0x78,0xd4,0xcf,0xf1,0xf4,0x4b,0xf2,0x9e,0xb4,0x7d,0x38,0x43,
         0xdd,0x5d,0x1b,0xbb,0xc3,0x5c,0x81,0x2d,0x9b,0x7b,0xfd,0xe1,0x54,0x9b,0x4c,0xa2],
        [0x8f,0x9d,0xd2,0xb4,0xc1,0x37,0x32,0xc6,0x99,0xb5,0x56,0x35,0x37,0xd2,0x83,0x0f,
         0x34,0x59,0x2d,0xe0,0x31,0xa2,0x73,0x70,0x7b,0x75,0x5c,0x49,0xca,0x59,0x64,0x80],
    ]
}
