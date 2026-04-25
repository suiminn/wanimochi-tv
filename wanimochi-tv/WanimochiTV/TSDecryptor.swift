/*
 * TSDecryptor.swift - AES-CBC/OFB TS stream decryption
 *
 * The GV-M2TV device internally descrambles MULTI2 via B-CAS, then
 * re-encrypts the clear TS stream with AES using the Contents Key.
 * This class decrypts the AES-encrypted TS packets received from EP1.
 *
 * Ported from gvm2tv-stream.c read_stream() AES decryption logic.
 */

import Foundation
import CommonCrypto

class TSDecryptor {
    /// Fixed IV from POC binary decryptStream function
    private static let tsIVInit: [UInt8] = [
        0xec, 0x8f, 0x4b, 0x6a, 0xd9, 0x2a, 0x36, 0x89,
        0x2b, 0xdf, 0xb6, 0x18, 0xfc, 0x25, 0x5e, 0xfc
    ]

    private let contentsKey: Data
    private let tsPacketSize = 188

    init(contentsKey: Data) {
        self.contentsKey = contentsKey
    }

    /// Decrypt a single TS packet in-place.
    /// Returns true if the packet was modified (was scrambled and decrypted).
    @discardableResult
    func decryptPacket(_ packet: inout Data) -> Bool {
        guard packet.count >= tsPacketSize else { return false }
        guard packet[0] == 0x47 else { return false }

        // Check scrambling control bits (bits 7-6 of byte 3)
        let sc = (packet[3] >> 6) & 0x03
        if sc == 0 { return false } // Not scrambled

        // Determine payload offset
        let adapt = (packet[3] >> 4) & 0x03
        let payloadOff: Int
        switch adapt {
        case 0x02: return false // Adaptation only, no payload
        case 0x03: payloadOff = 5 + Int(packet[4])
        default:   payloadOff = 4
        }

        guard payloadOff < tsPacketSize else { return false }

        let payloadLen = tsPacketSize - payloadOff
        let cbcLen = payloadLen & ~0x0F // Round down to AES block
        var iv = Data(Self.tsIVInit)

        packet.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let payload = bytes.baseAddress! + payloadOff

            // AES-CBC decrypt the block-aligned portion
            if cbcLen > 0 {
                var tempOut = [UInt8](repeating: 0, count: cbcLen)
                var cryptorIV = iv
                cryptorIV.withUnsafeMutableBytes { ivPtr in
                    contentsKey.withUnsafeBytes { keyPtr in
                        var bytesDecrypted = 0
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES128),
                                0,
                                keyPtr.baseAddress, 16,
                                ivPtr.baseAddress,
                                payload, cbcLen,
                                &tempOut, cbcLen,
                                &bytesDecrypted)
                        // Copy decrypted data back
                        memcpy(payload, &tempOut, cbcLen)
                        // Update IV to the last ciphertext block for OFB
                        // (IV was updated in-place by CCCrypt)
                    }
                }
            }

            // AES-OFB decrypt the remaining bytes (less than a block)
            let ofbLen = payloadLen - cbcLen
            if ofbLen > 0 {
                // OFB mode: encrypt IV to get keystream, XOR with data
                var keystream = [UInt8](repeating: 0, count: 16)
                var bytesEncrypted = 0
                iv.withUnsafeBytes { ivBytes in
                    contentsKey.withUnsafeBytes { keyPtr in
                        // ECB encrypt the IV to get keystream
                        CCCrypt(CCOperation(kCCEncrypt),
                                CCAlgorithm(kCCAlgorithmAES128),
                                CCOptions(kCCOptionECBMode),
                                keyPtr.baseAddress, 16,
                                nil,
                                ivBytes.baseAddress, 16,
                                &keystream, 16,
                                &bytesEncrypted)
                    }
                }

                // XOR with remaining payload bytes
                for i in 0..<ofbLen {
                    payload[cbcLen + i] ^= keystream[i]
                }
            }
        }

        // Clear scrambling bits
        packet[3] &= 0x3F
        return true
    }

    /// Decrypt multiple TS packets from a buffer.
    /// Returns the decrypted data.
    func decryptBuffer(_ data: Data) -> Data {
        var result = data
        var offset = 0

        while offset + tsPacketSize <= result.count {
            if result[offset] == 0x47 {
                var packet = Data(result[offset..<offset + tsPacketSize])
                decryptPacket(&packet)
                result.replaceSubrange(offset..<offset + tsPacketSize, with: packet)
                offset += tsPacketSize
            } else {
                offset += 1 // Seek to next sync byte
            }
        }

        return result
    }
}
