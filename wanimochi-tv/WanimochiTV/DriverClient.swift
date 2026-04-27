/*
 * DriverClient.swift - Direct USB communication with GV-M2TV
 *
 * Uses IOUSBLib COM interface for userspace USB access (no DEXT needed).
 * Equivalent to the original libusb-based driver.
 */

import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

class DriverClient {
    private var deviceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>?
    private var interfaceInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>>?

    private var cmdSeq: UInt8 = 0

    private let vendorID: UInt16 = 0x04BB
    private let productID: UInt16 = 0x053A
    private let timeoutMS: UInt32 = 3000

    // USB request types
    private let BREQ_API_CMD: UInt8 = 0xB8
    private let BREQ_REG_RW: UInt8 = 0xBC
    private let BREQ_I2C: UInt8 = 0xBD

    // I2C
    private let I2C_WINDEX: UInt16 = 0x1800

    // Registers
    private let REG_STATE: UInt32       = 0x82008
    private let REG_BOOT_TRIG: UInt32   = 0x90070
    private let REG_IRQ_STATUS: UInt32  = 0x90074
    private let REG_IRQ_ENABLE: UInt32  = 0x90078
    private let REG_SECURE_BASE: UInt32 = 0x83000
    private let REG_GPIO_CNT: UInt32    = 0x90014
    private let REG_GPIO_OUT: UInt32    = 0x90018

    var isConnected: Bool { deviceInterface != nil }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    func connect() throws {
        // Find USB device
        guard let matchDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary? else {
            throw GVM2TVError.deviceNotFound
        }
        matchDict[kUSBVendorID] = vendorID
        matchDict[kUSBProductID] = productID

        var usbDevice: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, matchDict)
        guard usbDevice != IO_OBJECT_NULL else {
            throw GVM2TVError.deviceNotFound
        }
        defer { IOObjectRelease(usbDevice) }
        print("[USB] Found GV-M2TV device")

        // Get device interface
        deviceInterface = try createDeviceInterface(usbDevice)
        guard let dev = deviceInterface else {
            throw GVM2TVError.deviceNotFound
        }

        // Open device
        var kr = dev.pointee.pointee.USBDeviceOpen(dev)
        if kr == kIOReturnExclusiveAccess {
            // Already open, try seize
            kr = dev.pointee.pointee.USBDeviceOpenSeize(dev)
        }
        guard kr == kIOReturnSuccess else {
            print("[USB] USBDeviceOpen failed: 0x\(String(kr, radix: 16))")
            throw GVM2TVError.openFailed(kr)
        }
        print("[USB] Device opened")

        // Configure device
        var configDesc = IOUSBConfigurationDescriptorPtr(bitPattern: 0)
        kr = dev.pointee.pointee.GetConfigurationDescriptorPtr(dev, 0, &configDesc)
        if kr == kIOReturnSuccess, let config = configDesc {
            kr = dev.pointee.pointee.SetConfiguration(dev, config.pointee.bConfigurationValue)
            print("[USB] Configuration set: \(config.pointee.bConfigurationValue)")
        }

        // Find and open interface 0
        interfaceInterface = try findInterface(dev, interfaceNumber: 0)
        guard let iface = interfaceInterface else {
            throw GVM2TVError.deviceNotFound
        }

        kr = iface.pointee.pointee.USBInterfaceOpen(iface)
        guard kr == kIOReturnSuccess else {
            print("[USB] USBInterfaceOpen failed: 0x\(String(kr, radix: 16))")
            throw GVM2TVError.openFailed(kr)
        }
        print("[USB] Interface 0 opened")
    }

    func disconnect() {
        if let iface = interfaceInterface {
            iface.pointee.pointee.USBInterfaceClose(iface)
            iface.pointee.pointee.Release(iface)
            interfaceInterface = nil
        }
        if let dev = deviceInterface {
            dev.pointee.pointee.USBDeviceClose(dev)
            dev.pointee.pointee.Release(dev)
            deviceInterface = nil
        }
    }

    // MARK: - USB Control Transfer

    private func controlTransfer(requestType: UInt8, request: UInt8,
                                  wValue: UInt16, wIndex: UInt16,
                                  data: UnsafeMutablePointer<UInt8>?, length: UInt16) throws -> Int {
        guard let dev = deviceInterface else {
            throw GVM2TVError.deviceNotFound
        }

        var req = IOUSBDevRequest(
            bmRequestType: requestType,
            bRequest: request,
            wValue: wValue,
            wIndex: wIndex,
            wLength: length,
            pData: data.map { UnsafeMutableRawPointer($0) },
            wLenDone: 0
        )

        let kr = dev.pointee.pointee.DeviceRequest(dev, &req)
        guard kr == kIOReturnSuccess else {
            throw GVM2TVError.iokitError(kr)
        }
        return Int(req.wLenDone)
    }

    // MARK: - Register Access (bRequest=0xBC)

    func regWrite(addr: UInt8 = 0, reg: UInt32, data: [UInt8]) throws {
        let wValue = UInt16(addr & 0xFF) | UInt16((reg >> 8) & 0xF00)
        let wIndex = UInt16(reg & 0xFFFF)
        var buf = data
        _ = try controlTransfer(requestType: 0x40, request: BREQ_REG_RW,
                                wValue: wValue, wIndex: wIndex,
                                data: &buf, length: UInt16(data.count))
    }

    func regRead(addr: UInt8 = 0, reg: UInt32, length: Int) throws -> [UInt8] {
        let wValue = UInt16(addr & 0xFF) | UInt16((reg >> 8) & 0xF00)
        let wIndex = UInt16(reg & 0xFFFF)
        var buf = [UInt8](repeating: 0, count: length)
        _ = try controlTransfer(requestType: 0xC0, request: BREQ_REG_RW,
                                wValue: wValue, wIndex: wIndex,
                                data: &buf, length: UInt16(length))
        return buf
    }

    // MARK: - API Command (bRequest=0xB8)

    func setApiCmd(_ cmd: inout [UInt8]) throws {
        cmd[1] = cmdSeq
        cmdSeq = (cmdSeq + 1 >= 0x3F) ? 0 : cmdSeq + 1
        _ = try controlTransfer(requestType: 0x40, request: BREQ_API_CMD,
                                wValue: 0x0000, wIndex: 0x0000,
                                data: &cmd, length: 6)
    }

    // MARK: - Interrupt Transfer (EP3 = pipe index for interrupt IN)

    func getAck(timeout: UInt32 = 3000) throws -> [UInt8] {
        guard let iface = interfaceInterface else {
            throw GVM2TVError.deviceNotFound
        }
        let pipeIndex = try findPipeIndex(for: 0x83)

        var buf = [UInt8](repeating: 0, count: 64)
        var size: UInt32 = 64
        let kr = iface.pointee.pointee.ReadPipeTO(
            iface,
            pipeIndex,
            &buf,
            &size,
            timeout,
            timeout
        )

        if kr == kIOReturnTimeout {
            return []
        }

        guard kr == kIOReturnSuccess else {
            print("[USB] EP3 ReadPipe error: 0x\(String(kr, radix: 16))")
            throw GVM2TVError.iokitError(kr)
        }

        let result = Array(buf[0..<Int(size)])
        if !result.isEmpty {
            print("[USB] EP3 read: \(result.count) bytes: \(result.map { String(format: "%02x", $0) }.joined(separator: " "))")
        }

        return result
    }

    // MARK: - I2C Proxy (bRequest=0xBD)

    func i2cWrite(data: [UInt8]) throws {
        var buf = data
        _ = try controlTransfer(requestType: 0x40, request: BREQ_I2C,
                                wValue: 0x0000, wIndex: I2C_WINDEX,
                                data: &buf, length: UInt16(data.count))
        // Confirmation read
        var status: [UInt8] = [0x08, 0x08]
        _ = try? controlTransfer(requestType: 0xC0, request: BREQ_I2C,
                                 wValue: 0x000F, wIndex: I2C_WINDEX,
                                 data: &status, length: 2)
    }

    func i2cRead(reg: UInt8, length: Int) throws -> [UInt8] {
        var addr: [UInt8] = [reg]
        _ = try controlTransfer(requestType: 0x40, request: BREQ_I2C,
                                wValue: 0x0000, wIndex: I2C_WINDEX,
                                data: &addr, length: 1)
        var status: [UInt8] = [0x08, 0x08]
        _ = try? controlTransfer(requestType: 0xC0, request: BREQ_I2C,
                                 wValue: 0x000F, wIndex: I2C_WINDEX,
                                 data: &status, length: 2)
        var buf = [UInt8](repeating: 0, count: length)
        _ = try controlTransfer(requestType: 0xC0, request: BREQ_I2C,
                                wValue: 0x0000, wIndex: I2C_WINDEX,
                                data: &buf, length: UInt16(length))
        var status2: [UInt8] = [0x08, 0x08]
        _ = try? controlTransfer(requestType: 0xC0, request: BREQ_I2C,
                                 wValue: 0x000F, wIndex: I2C_WINDEX,
                                 data: &status2, length: 2)
        return buf
    }

    // MARK: - Bulk Transfer

    func bulkWrite(data: [UInt8]) throws {
        guard let iface = interfaceInterface else {
            throw GVM2TVError.deviceNotFound
        }
        let pipeIndex = try findPipeIndex(for: 0x02)
        var buf = data
        let kr = iface.pointee.pointee.WritePipe(iface, pipeIndex, &buf, UInt32(data.count))
        guard kr == kIOReturnSuccess else {
            throw GVM2TVError.iokitError(kr)
        }
    }

    func bulkRead(length: Int) throws -> [UInt8] {
        guard let iface = interfaceInterface else {
            throw GVM2TVError.deviceNotFound
        }
        let pipeIndex = try findPipeIndex(for: 0x81)
        var buf = [UInt8](repeating: 0, count: length)
        var size = UInt32(length)
        let kr = iface.pointee.pointee.ReadPipe(iface, pipeIndex, &buf, &size)
        guard kr == kIOReturnSuccess else {
            throw GVM2TVError.iokitError(kr)
        }
        return Array(buf[0..<Int(size)])
    }

    /// Bulk read with timeout (ms). Returns empty array on timeout.
    func bulkReadWithTimeout(length: Int, timeout: UInt32) throws -> [UInt8] {
        guard let iface = interfaceInterface else {
            throw GVM2TVError.deviceNotFound
        }
        let pipeIndex = try findPipeIndex(for: 0x81)

        var buf = [UInt8](repeating: 0, count: length)
        var size = UInt32(length)
        let kr = iface.pointee.pointee.ReadPipeTO(
            iface,
            pipeIndex,
            &buf,
            &size,
            timeout,
            timeout
        )

        if kr == kIOReturnTimeout {
            return []
        }

        guard kr == kIOReturnSuccess else {
            throw GVM2TVError.iokitError(kr)
        }

        return Array(buf[0..<Int(size)])
    }

    // MARK: - High-Level Helpers

    func readDeviceState() throws -> UInt16 {
        let buf = try regRead(reg: REG_STATE, length: 2)
        return UInt16(buf[0]) << 8 | UInt16(buf[1])
    }

    func waitInterruptReady(timeoutMS: UInt32 = 5000) throws {
        var lastStatus: [UInt8] = []
        let deadline = Date().addingTimeInterval(Double(timeoutMS) / 1000.0)

        repeat {
            do {
                let buf = try regRead(reg: REG_IRQ_STATUS, length: 2)
                lastStatus = buf
                if buf.count >= 2 && buf[1] & 0x04 != 0 { return }
            } catch GVM2TVError.iokitError(let code) where code == kIOReturnTimeout {
                // A transient timeout can happen just after force reset while the device settles.
            }
            usleep(2000)
        } while Date() < deadline

        throw GVM2TVError.interruptReadyTimeout(lastStatus)
    }

    func clearPipeStall(endpoint: UInt8) throws {
        guard let iface = interfaceInterface else { return }
        let pipeIndex = try findPipeIndex(for: endpoint)
        iface.pointee.pointee.ClearPipeStallBothEnds(iface, pipeIndex)
    }

    func abortPipe(endpoint: UInt8) throws {
        guard let iface = interfaceInterface else { return }
        let pipeIndex = try findPipeIndex(for: endpoint)
        iface.pointee.pointee.AbortPipe(iface, pipeIndex)
    }

    func clearInterrupt() throws {
        try regWrite(reg: REG_IRQ_STATUS, data: [0x00, 0x04])
    }

    /// Full interrupt clear for shutdown sequences (matches C code's {0x07, 0xFC})
    func clearAllInterrupts() throws {
        try regWrite(reg: REG_IRQ_STATUS, data: [0x07, 0xFC])
    }

    func forceReset() throws {
        try sendApiCommand([0x00, 0x00, 0x0F, 0x00, 0x00, 0x00])
    }

    func bootTrigger() throws {
        try regWrite(reg: REG_BOOT_TRIG, data: [0x00, 0x04])
    }

    func setGPIO() throws {
        try regWrite(reg: REG_GPIO_CNT, data: [0x02, 0xF4])
        try regWrite(reg: REG_GPIO_OUT, data: [0x03, 0xFF])
    }

    func uploadFirmware(_ data: Data) throws {
        guard data.count >= 8, data.prefix(8) == Data("MB8AC018".utf8) else {
            throw GVM2TVError.invalidFirmware
        }
        // Clear halt on EP2
        if let iface = interfaceInterface {
            let pipeIndex = try findPipeIndex(for: 0x02)
            iface.pointee.pointee.ClearPipeStallBothEnds(iface, pipeIndex)
        }
        // Upload in 512-byte chunks
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let chunkSize = min(512, bytes.count - offset)
            let chunk = Array(bytes[offset..<offset + chunkSize])
            try bulkWrite(data: chunk)
            offset += chunkSize
        }
        print("[USB] Firmware uploaded (\(offset) bytes)")
    }

    // MARK: - Secure Register Access

    func secureRegWrite(baseReg: UInt32, data: Data) throws {
        var offset: UInt32 = 0
        while offset < data.count {
            let chunk = min(64, data.count - Int(offset))
            let slice = [UInt8](data[Int(offset)..<Int(offset) + chunk])
            try regWrite(reg: baseReg + offset, data: slice)
            offset += UInt32(chunk)
        }
    }

    func secureRegRead(baseReg: UInt32, length: Int) throws -> Data {
        var result = Data()
        var offset: UInt32 = 0
        while offset < length {
            let chunk = min(64, length - Int(offset))
            let buf = try regRead(reg: baseReg + offset, length: chunk)
            result.append(contentsOf: buf)
            offset += UInt32(chunk)
        }
        return result
    }

    func bcasRegWrite(reg: UInt32, data: Data) throws {
        try secureRegWrite(baseReg: reg, data: data)
    }

    func bcasRegRead(reg: UInt32, length: Int) throws -> Data {
        return try secureRegRead(baseReg: reg, length: length)
    }

    // MARK: - API Command Helpers

    func sendApiCommand(_ cmdBytes: [UInt8]) throws {
        var cmd = cmdBytes
        try setApiCmd(&cmd)
    }

    func sendApiCommand(_ cmdData: Data) throws {
        try sendApiCommand([UInt8](cmdData))
    }

    func getInterruptMessage(timeout: UInt32 = 3000) throws -> Data {
        let buf = try getAck(timeout: timeout)
        return Data(buf)
    }

    // MARK: - IOUSBLib Helpers

    private func createDeviceInterface(_ usbDevice: io_service_t) throws
        -> UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>> {

        var plugInInterface: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0

        let kr = IOCreatePlugInInterfaceForService(
            usbDevice,
            GVM2TV_kIOUSBDeviceUserClientTypeID(),
            GVM2TV_kIOCFPlugInInterfaceID(),
            &plugInInterface,
            &score)
        guard kr == kIOReturnSuccess, let plugin = plugInInterface, let _ = plugin.pointee else {
            throw GVM2TVError.iokitError(kr)
        }
        defer { _ = plugin.pointee!.pointee.Release(plugin) }

        var deviceInterfacePtr: UnsafeMutableRawPointer?
        let hr = plugin.pointee!.pointee.QueryInterface(
            plugin,
            CFUUIDGetUUIDBytes(GVM2TV_kIOUSBDeviceInterfaceID()),
            &deviceInterfacePtr)
        guard hr == S_OK, let ptr = deviceInterfacePtr else {
            throw GVM2TVError.iokitError(kIOReturnError)
        }

        return ptr.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>.self)
    }

    private func findInterface(_ dev: UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>>,
                               interfaceNumber: UInt8) throws
        -> UnsafeMutablePointer<UnsafeMutablePointer<IOUSBInterfaceInterface>> {

        var request = IOUSBFindInterfaceRequest(
            bInterfaceClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceSubClass: UInt16(kIOUSBFindInterfaceDontCare),
            bInterfaceProtocol: UInt16(kIOUSBFindInterfaceDontCare),
            bAlternateSetting: UInt16(kIOUSBFindInterfaceDontCare))

        var iterator: io_iterator_t = 0
        var kr = dev.pointee.pointee.CreateInterfaceIterator(dev, &request, &iterator)
        guard kr == kIOReturnSuccess else {
            throw GVM2TVError.iokitError(kr)
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }

            var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0
            kr = IOCreatePlugInInterfaceForService(
                service,
                GVM2TV_kIOUSBInterfaceUserClientTypeID(),
                GVM2TV_kIOCFPlugInInterfaceID(),
                &plugIn,
                &score)
            guard kr == kIOReturnSuccess, let plugin = plugIn, let _ = plugin.pointee else { continue }
            defer { _ = plugin.pointee!.pointee.Release(plugin) }

            var ifacePtr: UnsafeMutableRawPointer?
            let hr = plugin.pointee!.pointee.QueryInterface(
                plugin,
                CFUUIDGetUUIDBytes(GVM2TV_kIOUSBInterfaceInterfaceID()),
                &ifacePtr)
            guard hr == S_OK, let ptr = ifacePtr else { continue }

            let iface = ptr.assumingMemoryBound(
                to: UnsafeMutablePointer<IOUSBInterfaceInterface>.self)

            var ifNum: UInt8 = 0
            iface.pointee.pointee.GetInterfaceNumber(iface, &ifNum)
            if ifNum == interfaceNumber {
                return iface
            }
            _ = iface.pointee.pointee.Release(iface)
        }

        throw GVM2TVError.deviceNotFound
    }

    private func findPipeIndex(for endpointAddress: UInt8) throws -> UInt8 {
        guard let iface = interfaceInterface else {
            throw GVM2TVError.deviceNotFound
        }
        var numEndpoints: UInt8 = 0
        iface.pointee.pointee.GetNumEndpoints(iface, &numEndpoints)

        for i in 1...numEndpoints {
            var direction: UInt8 = 0
            var number: UInt8 = 0
            var transferType: UInt8 = 0
            var maxPacketSize: UInt16 = 0
            var interval: UInt8 = 0
            iface.pointee.pointee.GetPipeProperties(iface, i,
                                                     &direction, &number,
                                                     &transferType, &maxPacketSize, &interval)
            let addr = number | (direction == kUSBIn ? 0x80 : 0x00)
            if addr == endpointAddress {
                return i
            }
        }
        throw GVM2TVError.iokitError(kIOReturnNotFound)
    }
}

// MARK: - Error Type

enum GVM2TVError: LocalizedError {
    case deviceNotFound
    case openFailed(kern_return_t)
    case iokitError(kern_return_t)
    case invalidFirmware
    case firmwareNotFound(String)
    case authenticationFailed
    case bcasError(String)
    case noContentsKey
    case unexpectedState(UInt16)
    case recoveryFailed(UInt16)
    case interruptReadyTimeout([UInt8])

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "GV-M2TV device not found"
        case .openFailed(let code):
            return "Failed to open device: \(Self.formatIOReturn(code))"
        case .iokitError(let code):
            return "IOKit error: \(Self.formatIOReturn(code))"
        case .invalidFirmware:
            return "Invalid firmware file"
        case .firmwareNotFound(let name):
            return "\(name).bin not found"
        case .authenticationFailed:
            return "Certificate authentication failed"
        case .bcasError(let msg):
            return "B-CAS error: \(msg)"
        case .noContentsKey:
            return "No Contents Key available"
        case .unexpectedState(let state):
            return "Unexpected device state: 0x\(String(format: "%04x", state))"
        case .recoveryFailed(let state):
            return "Device recovery failed: 0x\(String(format: "%04x", state))"
        case .interruptReadyTimeout(let status):
            let statusText = status.isEmpty
                ? "unavailable"
                : status.map { String(format: "%02x", $0) }.joined(separator: " ")
            return "Timed out waiting for firmware upload ready (IRQ status: \(statusText))"
        }
    }

    private static func formatIOReturn(_ code: kern_return_t) -> String {
        String(format: "0x%08x", UInt32(bitPattern: code))
    }
}
