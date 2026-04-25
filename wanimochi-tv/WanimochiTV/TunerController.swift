/*
 * TunerController.swift - MJ111 Tuner/Demodulator control
 *
 * Controls the MJ111 ISDB-T tuner via I2C proxy commands.
 * Ported from gvm2tv-stream.c init_tuner() and tune_channel().
 */

import Foundation

class TunerController {
    private let client: DriverClient

    init(client: DriverClient) {
        self.client = client
    }

    // MARK: - I2C Table Types

    struct I2CEntry {
        let data: [UInt8]
    }

    // MARK: - Initialization

    func initTuner() throws {
        print("[Tuner] SW reset...")
        try writeTable(Self.tblTunerSwReset)
        usleep(50000)

        print("[Tuner] Demod init (26 regs)...")
        try writeTable(Self.tblDemodInit)

        // Verify I2C
        let r03 = try client.i2cRead(reg: 0x03, length: 1)
        print("[Tuner] reg 0x03 = 0x\(String(format: "%02x", r03[0])) \(r03[0] == 0x80 ? "(OK)" : "(MISMATCH!)")")

        print("[Tuner] Tuner init...")
        try writeTable(Self.tblTunerInit)

        print("[Tuner] MJ111 initialized")
    }

    // MARK: - Tuning

    func tune(channel: Int) throws -> Bool {
        guard (13...62).contains(channel) else {
            print("[Tuner] Invalid channel \(channel)")
            return false
        }

        let freqKHz = UInt32(channel * 6000 + 395143)
        print("[Tuner] Channel \(channel) -> \(freqKHz) kHz")

        // 1. Demod wakeup
        try writeTable(Self.tblDemodWakeup)
        // 2. Tuner wakeup
        try writeTable(Self.tblTunerWakeup)

        // 3. Stop stream
        try client.sendApiCommand([0x00, 0x00, 0x05, 0x00, 0x00, 0x00])
        _ = try client.getAck(timeout: 500)

        // 4-5. AGC/Sequencer stop
        try writeTable(Self.tblAGCStop)
        try writeTable(Self.tblSequencerStop)

        // 6. Bandwidth (6MHz)
        try writeTable(Self.tblBandwidth)

        // 7. Frequency
        let divider = UInt16((freqKHz * 64 + 500) / 1000)
        print("[Tuner] PLL divider: 0x\(String(format: "%04x", divider))")
        try client.i2cWrite(data: [0xFE, 0xC0, 0x0D, UInt8(divider & 0xFF), 0x0E, UInt8((divider >> 8) & 0xFF)])

        // 8. Default setting 1
        try writeTable(Self.tblDefaultSetting1)

        // 9. Default setting 2 (frequency threshold)
        let threshold: UInt8 = freqKHz < 333000 ? 0x01 : 0x41
        try client.i2cWrite(data: [0xFE, 0xC0, 0x80, threshold])

        // 10-12. Sequencer/AGC start
        try writeTable(Self.tblSequencerStart)
        try writeTable(Self.tblSyncSequencerStart)
        try writeTable(Self.tblAGCStart)

        // 13. Wait for lock
        print("[Tuner] Waiting for signal lock...")
        var locked = false
        for i in 0..<20 {
            usleep(100000) // 100ms
            let lockState = try checkLock()
            if lockState == 0 {
                print("[Tuner] LOCKED after \((i + 1) * 100)ms")
                locked = true
                break
            }
        }

        // Signal strength
        let strength = try getSignalStrength()
        print("[Tuner] Signal strength: \(strength)/100")

        if !locked {
            print("[Tuner] No signal lock after 2000ms")
        }

        // 14. TS enable
        print("[Tuner] Enabling TS output...")
        try writeTable(Self.tblTsEnable)

        return locked
    }

    // MARK: - Lock Detection

    func checkLock() throws -> Int {
        let r80 = try client.i2cRead(reg: 0x80, length: 1)[0]
        let rb0 = try client.i2cRead(reg: 0xB0, length: 1)[0]
        let r96 = try client.i2cRead(reg: 0x96, length: 1)[0]

        if r80 & 0x28 != 0 {
            return (r80 & 0x80 != 0) ? 0 : 1
        }
        if (rb0 & 0x0F) > 7 {
            return (r96 & 0xE0 != 0) ? 0 : 1
        }
        return 2
    }

    // MARK: - Signal Strength

    func getSignalStrength() throws -> Int {
        let s0 = try client.i2cRead(reg: 0x8B, length: 1)[0]
        let s1 = try client.i2cRead(reg: 0x8C, length: 1)[0]
        let s2 = try client.i2cRead(reg: 0x8D, length: 1)[0]
        let raw = (UInt32(s0) << 16) | (UInt32(s1) << 8) | UInt32(s2)
        if raw == 0 { return 0 }

        var level = 100
        for t in 0..<100 {
            if raw < Self.signalTable[t] { level = 100 - t; break }
        }
        if level == 100 && raw >= Self.signalTable[99] { level = 0 }
        return level
    }

    // MARK: - Sleep

    func sleep() throws {
        try writeTable(Self.tblTsDisable)
        try writeTable(Self.tblTunerSleep)
        try writeTable(Self.tblDemodSleep)
    }

    // MARK: - I2C Table Writer

    private func writeTable(_ entries: [[UInt8]]) throws {
        for entry in entries {
            try client.i2cWrite(data: entry)
        }
    }

    // MARK: - I2C Register Tables (from mj111_tables.h)

    static let tblTunerSwReset: [[UInt8]] = [
        [0xFE, 0xC0, 0xFF]
    ]

    static let tblDemodInit: [[UInt8]] = [
        [0x03, 0x80], [0x09, 0x10], [0x11, 0x26], [0x12, 0x0C],
        [0x13, 0x2B], [0x14, 0x40], [0x16, 0x00], [0x1C, 0x2A],
        [0x1D, 0xA0], [0x1E, 0xA8], [0x1F, 0xA8], [0x30, 0x00],
        [0x31, 0x0D], [0x32, 0x79], [0x34, 0x0F], [0x38, 0x00],
        [0x39, 0x94], [0x3A, 0x20], [0x3B, 0x21], [0x3C, 0x3F],
        [0x71, 0x00], [0x75, 0x28], [0x76, 0x0C], [0x77, 0x01],
        [0x7D, 0x80], [0xEF, 0x01]
    ]

    static let tblTunerInit: [[UInt8]] = [
        [0xFE, 0xC0, 0x00, 0x3F, 0x02, 0x00, 0x03, 0x48,
         0x04, 0x00, 0x05, 0x04, 0x06, 0x10, 0x2E, 0x15,
         0x30, 0x10, 0x45, 0x58, 0x48, 0x19, 0x52, 0x03,
         0x53, 0x44, 0x6A, 0x4B, 0x76, 0x00, 0x78, 0x18,
         0x7A, 0x17, 0x85, 0x06],
        [0xFE, 0xC0, 0x01, 0x01]
    ]

    static let tblDemodWakeup: [[UInt8]] = [
        [0x03, 0x80], [0x1C, 0x2A]
    ]

    static let tblTunerWakeup: [[UInt8]] = [
        [0xFE, 0xC0, 0x01, 0x01]
    ]

    static let tblAGCStop: [[UInt8]] = [
        [0x25, 0x00], [0x23, 0x4D]
    ]

    static let tblSequencerStop: [[UInt8]] = [
        [0xFE, 0xC0, 0x0F, 0x00]
    ]

    static let tblBandwidth: [[UInt8]] = [
        [0xFE, 0xC0, 0x0C, 0x15]
    ]

    static let tblDefaultSetting1: [[UInt8]] = [
        [0xFE, 0xC0, 0x1F, 0x87, 0x20, 0x1F, 0x21, 0x87, 0x22, 0x1F]
    ]

    static let tblSequencerStart: [[UInt8]] = [
        [0xFE, 0xC0, 0x0F, 0x01]
    ]

    static let tblSyncSequencerStart: [[UInt8]] = [
        [0x01, 0x40]
    ]

    static let tblAGCStart: [[UInt8]] = [
        [0x23, 0x4C]
    ]

    static let tblTsEnable: [[UInt8]] = [
        [0x1E, 0x80], [0x1F, 0x08]
    ]

    static let tblTsDisable: [[UInt8]] = [
        [0x1E, 0xA8], [0x1F, 0xA8]
    ]

    static let tblTunerSleep: [[UInt8]] = [
        [0xFE, 0xC0, 0x0F, 0x00, 0x01, 0x00]
    ]

    static let tblDemodSleep: [[UInt8]] = [
        [0x1E, 0xA8], [0x1F, 0xA8], [0x1C, 0xAA], [0x03, 0xF0]
    ]

    // Signal strength lookup table (from Mac driver binary)
    static let signalTable: [UInt32] = [
        22,23,24,25,26,27,28,29,31,32,33,35,36,38,40,42,44,46,48,50,
        53,56,59,62,65,69,72,77,81,86,91,97,103,109,116,124,132,142,
        152,163,175,188,203,219,237,257,280,305,333,364,400,440,486,
        539,599,668,748,840,949,1076,1226,1404,1616,1871,2179,2553,
        3010,3572,4268,5133,6215,7574,9288,11456,14205,17697,22134,
        27774,34938,44027,55546,70126,88557,111834,141220,178318,
        225192,284517,359803,455723,578602,737185,943867,1216799,
        1583680,2089200,2811329,3903296,5735416,9778432
    ]
}
