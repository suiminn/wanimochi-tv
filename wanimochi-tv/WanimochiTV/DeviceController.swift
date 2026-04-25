/*
 * DeviceController.swift - GV-M2TV device state machine orchestration
 *
 * Drives the device lifecycle via direct USB communication:
 * connection → FW upload → auth → B-CAS → tuning → TRC → streaming → HTTP
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
    @Published var httpURL: String = ""

    private let client = DriverClient()
    private var aesKey: Data?
    private var secureAuth: SecureAuth?
    private var bcasManager: BCASManager?
    private var streamingEngine: StreamingEngine?
    private var httpServer: TSHTTPServer?
    private var tuner: TunerController?

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

            if state == 0x0000 {
                print("[Init] Uploading IDLE firmware...")
                guard let fwURL = Bundle.main.url(forResource: "mb86h57_h58_aac_idle", withExtension: "bin") else {
                    let fwPath = Bundle.main.bundlePath + "/../../../Firmware/mb86h57_h58_aac_idle.bin"
                    guard FileManager.default.fileExists(atPath: fwPath) else {
                        lastError = "IDLE firmware not found"
                        return
                    }
                    let fwData = try Data(contentsOf: URL(fileURLWithPath: fwPath))
                    try await uploadAndBoot(fwData)
                    return
                }
                let fwData = try Data(contentsOf: fwURL)
                try await uploadAndBoot(fwData)

            } else if state == 0x0010 {
                print("[Init] Already in Secure state, authenticating...")
                try await authenticate()

            } else if state == 0x0011 {
                print("[Init] Already in Idle state")
                deviceStateText = "Idle"

            } else {
                lastError = "Unexpected state: 0x\(String(state, radix: 16))"
            }
        } catch {
            lastError = error.localizedDescription
            print("[Init] Failed: \(error)")
        }
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
        for poll in 0..<20 {
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

            let trcPath = Bundle.main.url(forResource: "mb86h57_h58_aac_trc", withExtension: "bin")
                ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/../../../Firmware/mb86h57_h58_aac_trc.bin")
            let trcData = try Data(contentsOf: trcPath)

            streamingEngine = StreamingEngine(client: client, contentsKey: contentsKey)
            try streamingEngine!.loadTRCFirmware(trcData)

            // Start HTTP server
            if httpServer == nil {
                httpServer = TSHTTPServer(port: 8888)
                httpServer?.onTuneRequest = { [weak self] ch in
                    guard let self = self else { return }
                    Task { @MainActor in
                        self.selectedChannel = ch
                        await self.changeCh(ch)
                    }
                }
                try httpServer!.start()
                httpURL = "http://localhost:8888"
            }
            httpServer?.currentChannel = selectedChannel
            httpServer?.signalStrength = signalStrength
            httpServer?.isStreaming = true

            // Start ffmpeg transcoder for HLS
            httpServer?.startFFmpeg()

            // Connect streaming to HTTP server
            streamingEngine?.onTSData = { [weak self] data in
                self?.httpServer?.feedTSData(data)
            }

            // Start streaming
            try streamingEngine!.start()
            isStreaming = true
            lastError = nil

        } catch {
            lastError = error.localizedDescription
            print("[Tune] Failed: \(error)")
        }
    }

    // MARK: - Channel Change

    private func changeCh(_ ch: Int) async {
        guard isStreaming else { return }
        do {
            print("[ChChange] Changing to CH\(ch)...")
            selectedChannel = ch

            // 1. Stop EP1 read loop (aborts blocking ReadPipe)
            print("[ChChange] Stopping stream...")
            streamingEngine?.stop()
            streamingEngine = nil
            isStreaming = false

            // Reset EP1 pipe for reuse
            try? client.clearPipeStall(endpoint: 0x81)
            try await Task.sleep(nanoseconds: 100_000_000)

            // 2. Clear pending interrupts (use full clear like C code: 0x07FC)
            print("[ChChange] Clearing interrupts...")
            try? client.clearAllInterrupts()
            for _ in 0..<5 {
                let ack = try? client.getAck(timeout: 100)
                if ack == nil || ack!.isEmpty { break }
                print("[ChChange] Flushed EP3: \(ack!.map { String(format: "%02x", $0) }.joined(separator: " "))")
            }

            // 3. I2C: TsDisable + TunerSleep + DemodSleep
            print("[ChChange] I2C sleep...")
            try? tuner?.sleep()

            // 4. Deactivate TRC (STOP subcmd=0x04)
            print("[ChChange] Deactivate TRC (phase 1)...")
            try client.sendApiCommand([0x00, 0x00, 0x05, 0x00, 0x00, 0x04])
            for _ in 0..<5 {
                let ack = try client.getAck(timeout: 2000)
                if !ack.isEmpty {
                    print("[ChChange] Phase1 ACK: \(ack.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    if ack[0] == 0x20 {
                        try? client.clearAllInterrupts()
                        break
                    }
                }
            }

            // 5. Clear interrupts after phase 1
            try? client.clearAllInterrupts()
            for _ in 0..<5 {
                let ack = try? client.getAck(timeout: 200)
                if ack == nil || ack!.isEmpty { break }
                if !ack!.isEmpty && ack![0] == 0x20 {
                    try? client.clearAllInterrupts()
                }
            }

            // 6. Drain EP1 with timeout (device buffers TS data that must be read)
            print("[ChChange] Draining EP1...")
            var drained = 0
            var gotNullTS = false
            for _ in 0..<500 {
                let data = try client.bulkReadWithTimeout(length: 4096, timeout: 2000)
                if data.isEmpty { break }
                drained += data.count
                for j in stride(from: 0, to: data.count - 3, by: 1) {
                    if data[j] == 0x47 && data[j+1] == 0x1F && data[j+2] == 0xFF {
                        gotNullTS = true
                        break
                    }
                }
                if gotNullTS { break }
                usleep(1000)
            }
            print("[ChChange] Drained \(drained) bytes (nullTS=\(gotNullTS))")

            // 7. Clear interrupts before phase 2
            try? client.clearAllInterrupts()
            for _ in 0..<5 {
                let ack = try? client.getAck(timeout: 200)
                if ack == nil || ack!.isEmpty { break }
                if !ack!.isEmpty && ack![0] == 0x20 {
                    try? client.clearAllInterrupts()
                }
            }

            // 8. Transition to IDLE (STOP subcmd=0x01)
            print("[ChChange] Transition to IDLE (phase 2)...")
            try client.sendApiCommand([0x00, 0x00, 0x05, 0x00, 0x00, 0x01])
            for _ in 0..<5 {
                let ack = try client.getAck(timeout: 2000)
                if !ack.isEmpty {
                    print("[ChChange] Phase2 ACK: \(ack.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    if ack[0] == 0x20 {
                        try? client.clearAllInterrupts()
                        break
                    }
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)

            // 9. Poll state until IDLE (may take a few attempts)
            var state: UInt16 = 0
            for retry in 0..<10 {
                state = try client.readDeviceState()
                print("[ChChange] State poll \(retry): 0x\(String(state, radix: 16))")
                if state == 0x0011 { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            updateState(state)

            guard state == 0x0011 else {
                lastError = "Failed to return to IDLE: 0x\(String(state, radix: 16))"
                return
            }

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
            let trcPath = Bundle.main.url(forResource: "mb86h57_h58_aac_trc", withExtension: "bin")
                ?? URL(fileURLWithPath: Bundle.main.bundlePath + "/../../../Firmware/mb86h57_h58_aac_trc.bin")
            let trcData = try Data(contentsOf: trcPath)

            streamingEngine = StreamingEngine(client: client, contentsKey: contentsKey)
            try streamingEngine!.loadTRCFirmware(trcData)

            // 10. Reconnect to HTTP server + restart ffmpeg
            httpServer?.clearSegments()
            httpServer?.startFFmpeg()
            httpServer?.currentChannel = ch
            httpServer?.signalStrength = signalStrength

            streamingEngine?.onTSData = { [weak self] data in
                self?.httpServer?.feedTSData(data)
            }
            try streamingEngine!.start()
            isStreaming = true
            lastError = nil
            print("[ChChange] Channel change to CH\(ch) complete")

        } catch {
            lastError = "Channel change failed: \(error.localizedDescription)"
            print("[ChChange] Failed: \(error)")
        }
    }

    // MARK: - Stop

    func stopStreaming() async {
        streamingEngine?.stop()
        streamingEngine = nil
        httpServer?.isStreaming = false
        isStreaming = false
    }

    // MARK: - Helpers

    private func updateState(_ state: UInt16) {
        switch state {
        case 0x0000: deviceStateText = "No Firmware"
        case 0x0001: deviceStateText = "Transcode"
        case 0x0010: deviceStateText = "Secure"
        case 0x0011: deviceStateText = "Idle"
        case 0x0012: deviceStateText = "Sleep"
        default: deviceStateText = "Unknown (0x\(String(state, radix: 16)))"
        }
    }
}
