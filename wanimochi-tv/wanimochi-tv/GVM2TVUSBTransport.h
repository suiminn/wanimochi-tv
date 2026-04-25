/*
 * GVM2TVUSBTransport.h - USB transfer wrapper for GV-M2TV
 *
 * Encapsulates all USB communication: control transfers (register R/W, I2C, API),
 * bulk transfers (firmware upload, TS streaming), and interrupt transfers (ACK).
 *
 * Maps libusb operations to DriverKit IOUSBHostInterface/IOUSBHostPipe APIs.
 */

#ifndef GVM2TVUSBTransport_h
#define GVM2TVUSBTransport_h

#include <stdint.h>
#include <DriverKit/IOTypes.h>

class IOUSBHostInterface;
class IOUSBHostPipe;
class IOBufferMemoryDescriptor;

class GVM2TVUSBTransport {
public:
    GVM2TVUSBTransport();
    ~GVM2TVUSBTransport();

    /* Initialize: open pipes for all 4 endpoints */
    kern_return_t init(IOUSBHostInterface *interface);

    /* ---- Register Access (bRequest=0xBC) ---- */

    /*
     * Write to MB86H57 register.
     * addr: usually 0
     * reg: 20-bit register address (e.g. 0x82008)
     * data/len: data to write
     *
     * Maps to: control transfer OUT (0x40), bReq=0xBC
     *   wValue = (addr & 0xFF) | ((reg >> 8) & 0xF00)
     *   wIndex = reg & 0xFFFF
     */
    kern_return_t regWrite(uint8_t addr, uint32_t reg, const uint8_t *data, int len);

    /*
     * Read from MB86H57 register.
     * Maps to: control transfer IN (0xC0), bReq=0xBC
     */
    kern_return_t regRead(uint8_t addr, uint32_t reg, uint8_t *data, int len);

    /* ---- API Command (bRequest=0xB8) ---- */

    /*
     * Send 6-byte API command. Auto-increments sequence number in cmd[1].
     * Maps to: control transfer OUT (0x40), bReq=0xB8, wValue=0, wIndex=0
     */
    kern_return_t setApiCmd(uint8_t *cmd6);

    /* ---- Interrupt Transfer (EP3) ---- */

    /*
     * Read ACK/status from EP3.
     * Returns number of bytes received, or negative on error.
     * 0 = timeout (no data).
     */
    int getAck(uint8_t *buf, uint32_t timeout_ms);

    /* ---- I2C Proxy (bRequest=0xBD) ---- */

    /*
     * Write data to MJ111 demod/tuner via I2C bridge.
     * Maps to: control transfer OUT (0x40), bReq=0xBD
     *   wValue=0x0000, wIndex=0x1800 ((0x30<<7) & 0x3F00)
     * Followed by confirmation read (wValue=0x000F).
     */
    kern_return_t i2cWrite(const uint8_t *data, int len);

    /*
     * Read from MJ111 demod register via I2C bridge.
     * Two-phase: write register address, then read data back.
     */
    kern_return_t i2cRead(uint8_t reg, uint8_t *buf, int len);

    /*
     * Write a sequence of I2C table entries.
     * Table is terminated by an entry with count=0.
     */
    struct TunerI2CWriteData {
        uint8_t count;
        uint8_t data[64];
    } __attribute__((packed));

    kern_return_t i2cWriteTable(const TunerI2CWriteData *tbl);

    /* ---- Bulk Transfer (EP1/EP2) ---- */

    /*
     * Upload firmware via EP2 bulk OUT.
     * Validates "MB8AC018" header and sends in 512-byte chunks.
     */
    kern_return_t uploadFirmware(const uint8_t *data, uint32_t len);

    /*
     * Read from EP1 bulk IN (TS stream data).
     * Returns number of bytes read in *transferred.
     */
    kern_return_t bulkRead(uint8_t *buf, uint32_t len, uint32_t *transferred,
                           uint32_t timeout_ms);

    /* ---- High-Level Helpers ---- */

    /* Read device state from REG_STATE (0x82008) */
    uint16_t readDeviceState();

    /* Wait for IRQ ready bit (poll REG_IRQ_STATUS) */
    kern_return_t waitInterruptReady();

    /* Clear interrupt status */
    kern_return_t clearInterrupt();

    /* Trigger firmware boot (write to REG_BOOT_TRIG) */
    kern_return_t bootTrigger();

    /* Clear endpoint halt/stall */
    kern_return_t clearHalt(uint8_t endpointAddr);

    /* Get the EP1 pipe for async I/O */
    IOUSBHostPipe *getEP1Pipe() { return ep1Pipe_; }

private:
    IOUSBHostInterface       *interface_;
    IOUSBHostPipe            *ep1Pipe_;   /* 0x81: Bulk IN - TS stream */
    IOUSBHostPipe            *ep2Pipe_;   /* 0x02: Bulk OUT - FW upload */
    IOUSBHostPipe            *ep3Pipe_;   /* 0x83: Interrupt IN - ACK */
    IOUSBHostPipe            *ep4Pipe_;   /* 0x84: Bulk IN - 1-seg (unused) */
    IOBufferMemoryDescriptor *ctrlBuf_;   /* Reusable buffer for control transfers */
    uint8_t                   cmdSeq_;    /* API command sequence number */
};

#endif /* GVM2TVUSBTransport_h */
