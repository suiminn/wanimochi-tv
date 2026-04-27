/*
 * DeviceController.swift - GV-M2TV device state machine orchestration
 *
 * Drives the device lifecycle via direct USB communication:
 * connection → FW upload → auth → B-CAS → tuning → TRC → streaming → VLCKit
 */

import Foundation

@MainActor
class DeviceController: ObservableObject {
    @Published var deviceStateText: String = "Disconnected"
    @Published var isConnected: Bool = false
    @Published var signalLocked: Bool = false
    @Published var signalStrength: Int = 0
    @Published var isStreaming: Bool = false
    @Published var selectedChannel: Int = 27
    @Published var lastError: String?
    @Published var playerStreamURL: URL?
    @Published var playbackToken = UUID()

    private let client = DriverClient()
    private var aesKey: Data?
    private var secureAuth: SecureAuth?
    private var bcasManager: BCASManager?
    private var streamingEngine: StreamingEngine?
    private var directStreamSink: DirectTSStreamSink?
    private var tuner: TunerController?
    private var isShuttingDown = false

    // MARK: - Connection

    func connect() async {
        do {
            try client.connect()
            let state = try client.readDeviceState()
            print("[DeviceController] Device state: 0x\(String(state, radix: 16))")
            updateState(state)
            isConnected = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[DeviceController] Connect failed: \(error)")
        }
    }

    // MARK: - Initialize (FW upload → boot → auth → B-CAS)

    func initialize() async {
        do {
            let state = try client.readDeviceState()
            print("[Init] Current state: 0x\(String(state, radix: 16))")

            try await initialize(from: state, allowSessionReset: true)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            print("[Init] Failed: \(error)")
        }
    }

    private func initialize(from state: UInt16, allowSessionReset: Bool) async throws {
        switch state {
        case 0x0000:
            print("[Init] Uploading IDLE firmware...")
            let fwData = try loadFirmware(named: "mb86h57_h58_aac_idle")
            try await uploadAndBoot(fwData)

        case 0x0001, 0xFFFF:
            guard allowSessionReset else {
                throw GVM2TVError.recoveryFailed(state)
            }
            print("[Init] Device is in stale state 0x\(String(format: "%04x", state)); recovering...")
            let recoveredState = try await recoverDeviceSession(logPrefix: "[Init]")
            try await initialize(from: recoveredState, allowSessionReset: false)

        case 0x0010:
            print("[Init] Already in Secure state, authenticating...")
            try await authenticate()

        case 0x0011:
            print("[Init] Already in Idle state")
            deviceStateText = "Idle"
            if bcasManager?.contentsKey == nil {
                if aesKey == nil {
                    if allowSessionReset {
                        print("[Init] No session key in this app instance; resetting auth session...")
                        let recoveredState = try await resetDeviceSession(logPrefix: "[Init]")
                        try await initialize(from: recoveredState, allowSessionReset: false)
                    } else {
                        print("[Init] Reset kept device in Idle; attempting authentication...")
                        try await authenticate()
                    }
                } else {
                    try initBCAS()
                }
            }

        default:
            throw GVM2TVError.unexpectedState(state)
        }
    }

    private func loadFirmware(named name: String) throws -> Data {
        if let fwURL = Bundle.main.url(forResource: name, withExtension: "bin") {
            return try Data(contentsOf: fwURL)
        }

        let fwPath = Bundle.main.bundlePath + "/../../../Firmware/\(name).bin"
        guard FileManager.default.fileExists(atPath: fwPath) else {
            throw GVM2TVError.firmwareNotFound(name)
        }
        return try Data(contentsOf: URL(fileURLWithPath: fwPath))
    }

    private func uploadAndBoot(_ fwData: Data) async throws {
        print("[Init] Waiting for IRQ ready...")
        try client.waitInterruptReady()
        try client.clearInterrupt()

        print("[Init] Uploading firmware (\(fwData.count) bytes)...")
        try client.uploadFirmware(fwData)

        print("[Init] Boot trigger...")
        try client.bootTrigger()

        print("[Init] Waiting for boot...")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let newState = try client.readDeviceState()
        print("[Init] New state: 0x\(String(newState, radix: 16))")
        updateState(newState)

        if newState == 0x0010 {
            try await authenticate()
        }
    }

    private func authenticate() async throws {
        print("[Init] Certificate authentication...")
        self.secureAuth = SecureAuth(client: client)
        self.aesKey = try secureAuth!.performAuthentication()
        print("[Init] AES key derived: \(aesKey!.map { String(format: "%02x", $0) }.joined())")

        // Send IDLE command (cmd[2]=0x01)
        print("[Init] Sending IDLE command...")
        var idleCmd: [UInt8] = [0x00, 0x00, 0x01, 0x00, 0x00, 0x00]
        try client.setApiCmd(&idleCmd)

        for i in 0..<30 {
            let msg = try client.getAck(timeout: 500)
            if !msg.isEmpty {
                print("[Init] ACK[\(i)]: \(msg.map { String(format: "%02x", $0) }.joined(separator: " "))")
                if msg[0] == 0x20 {
                    print("[Init] STATE_CHANGE received!")
                    break
                }
            }
        }

        try client.clearInterrupt()
        try await Task.sleep(nanoseconds: 200_000_000)

        var state: UInt16 = 0
        for retry in 0..<5 {
            state = try client.readDeviceState()
            print("[Init] State poll \(retry): 0x\(String(state, radix: 16))")
            if state == 0x0011 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        updateState(state)

        if state == 0x0011 {
            try initBCAS()
        }
        lastError = nil
    }

    // MARK: - B-CAS Initialization

    private func initBCAS() throws {
        guard let key = aesKey else { return }

        print("[BCAS] Initializing B-CAS card reader...")
        try client.sendApiCommand([0x00, 0x00, 0x0A, 0x00, 0x00, 0x01])
        let resetAck = try client.getAck(timeout: 2000)
        print("[BCAS] Reset ACK: \(resetAck.map { String(format: "%02x", $0) }.joined(separator: " "))")

        try client.sendApiCommand([0x00, 0x00, 0x0A, 0x01, 0x00, 0x01])
        let initAck = try client.getAck(timeout: 2000)
        print("[BCAS] Init ACK: \(initAck.map { String(format: "%02x", $0) }.joined(separator: " "))")

        print("[BCAS] Waiting for card ready...")
        for _ in 0..<20 {
            let st = try client.regRead(reg: 0x822AC, length: 2)
            let nibble = (st[0] >> 4) & 0x0F
            if nibble == 3 { print("[BCAS] Card READY"); break }
            if nibble != 2 { break }
            usleep(20000)
        }

        bcasManager = BCASManager(client: client, aesKey: key)
        bcasManager?.secureAuth = secureAuth
        try bcasManager?.sendINTCommand()
        try bcasManager?.sendIDICommand()
        try bcasManager?.retainSecureEP()

        if let ck = bcasManager?.contentsKey {
            print("[BCAS] Contents Key: \(ck.map { String(format: "%02x", $0) }.joined())")
        }
        print("[BCAS] B-CAS initialization complete")
    }

    // MARK: - Tune + Start Streaming

    func tuneAndStream() async {
        do {
            // GPIO init
            try client.setGPIO()

            // Tuner init + tune
            tuner = TunerController(client: client)
            print("[Tune] Initializing MJ111...")
            try tuner!.initTuner()

            print("[Tune] Tuning to channel \(selectedChannel)...")
            signalLocked = try tuner!.tune(channel: selectedChannel)
            signalStrength = (try? tuner!.getSignalStrength()) ?? 0

            if !signalLocked {
                lastError = "No signal lock on CH\(selectedChannel)"
                return
            }

            // Load TRC firmware
            print("[Tune] Loading TRC firmware...")
            guard let contentsKey = bcasManager?.contentsKey else {
                lastError = "No Contents Key"
                return
            }

            let trcData = try loadFirmware(named: "mb86h57_h58_aac_trc")

            streamingEngine = StreamingEngine(client: client, contentsKey: contentsKey)
            try streamingEngine!.loadTRCFirmware(trcData)

            // Connect decrypted TS directly to VLCKit through a FIFO.
            let streamSink = DirectTSStreamSink(channel: selectedChannel)
            playerStreamURL = try streamSink.prepare()
            playbackToken = UUID()
            directStreamSink = streamSink

            streamingEngine?.onTSData = { data in
                streamSink.write(data)
            }

            // Start streaming
            try streamingEngine!.start()
            isStreaming = true
            lastError = nil

        } catch {
            directStreamSink?.close()
            directStreamSink = nil
            playerStreamURL = nil
            playbackToken = UUID()
            lastError = error.localizedDescription
            print("[Tune] Failed: \(error)")
        }
    }

    // MARK: - Channel Change

    func playSelectedChannel() async {
        if isStreaming {
            await changeCh(selectedChannel)
        } else {
            await tuneAndStream()
        }
    }

    private func changeCh(_ ch: Int) async {
        guard isStreaming else { return }
        do {
            print("[ChChange] Changing to CH\(ch)...")
            selectedChannel = ch

            try await stopStreamingPipeline(logPrefix: "[ChChange]", forceReset: false)

            // 8. GPIO + re-tune
            try client.setGPIO()
            tuner = TunerController(client: client)
            try tuner!.initTuner()
            print("[ChChange] Tuning to CH\(ch)...")
            signalLocked = try tuner!.tune(channel: ch)
            signalStrength = (try? tuner!.getSignalStrength()) ?? 0

            if !signalLocked {
                lastError = "No signal lock on CH\(ch)"
                return
            }

            // 9. Reload TRC firmware
            guard let contentsKey = bcasManager?.contentsKey else {
                lastError = "No Contents Key"
                return
            }
            let trcData = try loadFirmware(named: "mb86h57_h58_aac_trc")

            streamingEngine = StreamingEngine(client: client, contentsKey: contentsKey)
            try streamingEngine!.loadTRCFirmware(trcData)

            // 10. Reconnect direct VLCKit stream sink
            let streamSink = DirectTSStreamSink(channel: ch)
            playerStreamURL = try streamSink.prepare()
            playbackToken = UUID()
            directStreamSink = streamSink

            streamingEngine?.onTSData = { data in
                streamSink.write(data)
            }
            try streamingEngine!.start()
            isStreaming = true
            lastError = nil
            print("[ChChange] Channel change to CH\(ch) complete")

        } catch {
            directStreamSink?.close()
            directStreamSink = nil
            playerStreamURL = nil
            playbackToken = UUID()
            lastError = "Channel change failed: \(error.localizedDescription)"
            print("[ChChange] Failed: \(error)")
        }
    }

    // MARK: - Stop

    func stopStreaming() async {
        do {
            try await stopStreamingPipeline(logPrefix: "[Stop]", forceReset: false)
            lastError = nil
        } catch {
            lastError = "Stop failed: \(error.localizedDescription)"
            print("[Stop] Failed: \(error)")
        }
    }

    func shutdownForQuit() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        print("[Shutdown] Starting graceful shutdown...")

        if client.isConnected {
            do {
                try await stopStreamingPipeline(logPrefix: "[Shutdown]", forceReset: true)
            } catch {
                print("[Shutdown] Graceful device stop failed: \(error)")
            }
        }

        streamingEngine?.stop()
        streamingEngine = nil
        directStreamSink?.close()
        directStreamSink = nil
        tuner = nil
        bcasManager = nil
        secureAuth = nil
        aesKey = nil
        client.disconnect()
        signalLocked = false
        signalStrength = 0
        isStreaming = false
        playerStreamURL = nil
        playbackToken = UUID()
        isConnected = false
        deviceStateText = "Disconnected"
        isShuttingDown = false
        print("[Shutdown] Complete")
    }

    private func stopStreamingPipeline(logPrefix: String, forceReset: Bool) async throws {
        let shouldStopDevice = streamingEngine != nil || isStreaming
        streamingEngine?.stop()
        streamingEngine = nil
        directStreamSink?.close()
        directStreamSink = nil
        isStreaming = false
        playerStreamURL = nil
        playbackToken = UUID()

        guard client.isConnected else { return }

        let currentState = try? client.readDeviceState()
        guard shouldStopDevice || currentState == 0x0001 || currentState == 0xFFFF else {
            if let currentState {
                updateState(currentState)
            }
            return
        }

        try? client.abortPipe(endpoint: 0x81)
        try? client.clearPipeStall(endpoint: 0x81)
        try await Task.sleep(nanoseconds: 100_000_000)

        try await returnDeviceToIdle(logPrefix: logPrefix)

        if forceReset {
            let state = try await resetDeviceSession(logPrefix: logPrefix)
            updateState(state)
        }
    }

    private func recoverDeviceSession(logPrefix: String) async throws -> UInt16 {
        try? client.abortPipe(endpoint: 0x81)
        try? client.clearPipeStall(endpoint: 0x81)
        flushInterrupts(logPrefix: logPrefix, timeout: 100)

        do {
            try await returnDeviceToIdle(logPrefix: logPrefix)
        } catch {
            print("\(logPrefix) Return-to-idle recovery failed: \(error)")
        }

        return try await resetDeviceSession(logPrefix: logPrefix)
    }

    @discardableResult
    private func resetDeviceSession(logPrefix: String) async throws -> UInt16 {
        print("\(logPrefix) Force reset...")
        try client.forceReset()
        _ = try? client.getAck(timeout: 2000)
        flushInterrupts(logPrefix: logPrefix, timeout: 100)
        try await Task.sleep(nanoseconds: 500_000_000)

        let state = try await pollDeviceState(logPrefix: logPrefix, retries: 10)
        guard state != 0xFFFF else {
            throw GVM2TVError.recoveryFailed(state)
        }
        return state
    }

    private func returnDeviceToIdle(logPrefix: String) async throws {
        print("\(logPrefix) Clearing interrupts...")
        flushInterrupts(logPrefix: logPrefix, timeout: 100)

        print("\(logPrefix) I2C sleep...")
        try? tuner?.sleep()

        print("\(logPrefix) Deactivate TRC (phase 1)...")
        try sendStopCommand(subcommand: 0x04, label: "Phase1", logPrefix: logPrefix)

        flushInterrupts(logPrefix: logPrefix, timeout: 200)
        try drainBulkIn(logPrefix: logPrefix)
        flushInterrupts(logPrefix: logPrefix, timeout: 200)

        print("\(logPrefix) Transition to IDLE (phase 2)...")
        try sendStopCommand(subcommand: 0x01, label: "Phase2", logPrefix: logPrefix)
        try await Task.sleep(nanoseconds: 500_000_000)

        let state = try await pollDeviceState(logPrefix: logPrefix, retries: 10)
        updateState(state)

        guard state == 0x0011 else {
            throw GVM2TVError.recoveryFailed(state)
        }
    }

    private func sendStopCommand(subcommand: UInt8, label: String, logPrefix: String) throws {
        try client.sendApiCommand([0x00, 0x00, 0x05, 0x00, 0x00, subcommand])
        for _ in 0..<5 {
            let ack = try client.getAck(timeout: 2000)
            if !ack.isEmpty {
                print("\(logPrefix) \(label) ACK: \(ack.map { String(format: "%02x", $0) }.joined(separator: " "))")
                if ack[0] == 0x20 {
                    try? client.clearAllInterrupts()
                    break
                }
            }
        }
    }

    private func flushInterrupts(logPrefix: String, timeout: UInt32) {
        try? client.clearAllInterrupts()
        for _ in 0..<5 {
            let ack = try? client.getAck(timeout: timeout)
            if ack == nil || ack!.isEmpty { break }
            print("\(logPrefix) Flushed EP3: \(ack!.map { String(format: "%02x", $0) }.joined(separator: " "))")
            if ack![0] == 0x20 {
                try? client.clearAllInterrupts()
            }
        }
    }

    private func drainBulkIn(logPrefix: String) throws {
        print("\(logPrefix) Draining EP1...")
        var drained = 0
        var gotNullTS = false
        for _ in 0..<500 {
            let data = try client.bulkReadWithTimeout(length: 4096, timeout: 2000)
            if data.isEmpty { break }
            drained += data.count
            if data.count >= 3 {
                for j in stride(from: 0, through: data.count - 3, by: 1) {
                    if data[j] == 0x47 && data[j + 1] == 0x1F && data[j + 2] == 0xFF {
                        gotNullTS = true
                        break
                    }
                }
            }
            if gotNullTS { break }
            usleep(1000)
        }
        print("\(logPrefix) Drained \(drained) bytes (nullTS=\(gotNullTS))")
    }

    private func pollDeviceState(logPrefix: String, retries: Int) async throws -> UInt16 {
        var state: UInt16 = 0xFFFF
        for retry in 0..<retries {
            state = try client.readDeviceState()
            print("\(logPrefix) State poll \(retry): 0x\(String(format: "%04x", state))")
            if state == 0x0000 || state == 0x0010 || state == 0x0011 {
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return state
    }

    // MARK: - Helpers

    private func updateState(_ state: UInt16) {
        switch state {
        case 0x0000: deviceStateText = "No Firmware"
        case 0x0001: deviceStateText = "Transcode"
        case 0x0010: deviceStateText = "Secure"
        case 0x0011: deviceStateText = "Idle"
        case 0x0012: deviceStateText = "Sleep"
        case 0xFFFF: deviceStateText = "Communication Error (0xffff)"
        default: deviceStateText = "Unknown (0x\(String(state, radix: 16)))"
        }
    }
}
