/*
 * GVM2TVUSBTransport.cpp - USB transfer implementation for GV-M2TV
 *
 * Translates all USB operations from the original libusb-based driver
 * to DriverKit IOUSBHostInterface/IOUSBHostPipe APIs.
 */

#include <os/log.h>
#include <string.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>

#include "GVM2TVUSBTransport.h"
#include "GVM2TVShared.h"

#define LOG_PREFIX "GVM2TVTransport"
#define CTRL_BUF_SIZE 512

GVM2TVUSBTransport::GVM2TVUSBTransport()
    : interface_(nullptr)
    , ep1Pipe_(nullptr)
    , ep2Pipe_(nullptr)
    , ep3Pipe_(nullptr)
    , ep4Pipe_(nullptr)
    , ctrlBuf_(nullptr)
    , cmdSeq_(0)
{
}

GVM2TVUSBTransport::~GVM2TVUSBTransport()
{
    OSSafeReleaseNULL(ep1Pipe_);
    OSSafeReleaseNULL(ep2Pipe_);
    OSSafeReleaseNULL(ep3Pipe_);
    OSSafeReleaseNULL(ep4Pipe_);
    OSSafeReleaseNULL(ctrlBuf_);
    /* interface_ is owned by GVM2TVDriver, not released here */
}

kern_return_t GVM2TVUSBTransport::init(IOUSBHostInterface *interface)
{
    interface_ = interface;
    kern_return_t ret;

    /* Allocate reusable control transfer buffer */
    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, CTRL_BUF_SIZE, 0, &ctrlBuf_);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": ctrl buffer alloc failed: 0x%x", ret);
        return ret;
    }

    /* Copy pipes for each endpoint */

    /* EP1: 0x81 Bulk IN - TS stream */
    ret = interface_->CopyPipe(GVM2TV_EP_BULK_IN1, &ep1Pipe_);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": CopyPipe EP1 (0x81) failed: 0x%x", ret);
        return ret;
    }

    /* EP2: 0x02 Bulk OUT - FW upload */
    ret = interface_->CopyPipe(GVM2TV_EP_BULK_OUT, &ep2Pipe_);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": CopyPipe EP2 (0x02) failed: 0x%x", ret);
        return ret;
    }

    /* EP3: 0x83 Interrupt IN - ACK/status */
    ret = interface_->CopyPipe(GVM2TV_EP_INT_IN, &ep3Pipe_);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": CopyPipe EP3 (0x83) failed: 0x%x", ret);
        return ret;
    }

    /* EP4: 0x84 Bulk IN - 1-seg (optional) */
    ret = interface_->CopyPipe(GVM2TV_EP_BULK_IN2, &ep4Pipe_);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": CopyPipe EP4 (0x84) failed (non-fatal): 0x%x", ret);
        /* EP4 is optional - don't fail init */
        ep4Pipe_ = nullptr;
    }

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": initialized, pipes: EP1=%p EP2=%p EP3=%p EP4=%p",
           ep1Pipe_, ep2Pipe_, ep3Pipe_, ep4Pipe_);
    return kIOReturnSuccess;
}

/* ---- Register Access ---- */

kern_return_t GVM2TVUSBTransport::regWrite(uint8_t addr, uint32_t reg,
                                           const uint8_t *data, int len)
{
    if (!interface_ || !ctrlBuf_ || len <= 0 || len > CTRL_BUF_SIZE) {
        return kIOReturnBadArgument;
    }

    uint16_t wValue = (addr & 0xFF) | ((reg >> 8) & 0xF00);
    uint16_t wIndex = reg & 0xFFFF;

    /* Copy data to IOBufferMemoryDescriptor */
    uint64_t bufAddr = 0, bufLen = 0;
    kern_return_t ret = ctrlBuf_->Map(0, 0, 0, 0, &bufAddr, &bufLen);
    if (ret != kIOReturnSuccess) return ret;
    memcpy(reinterpret_cast<void *>(bufAddr), data, len);

    uint16_t bytesTransferred = 0;
    ret = interface_->DeviceRequest(
        /* bmRequestType */ 0x40,       /* Vendor, Host-to-Device */
        /* bRequest */      GVM2TV_BREQ_REG_RW,
        /* wValue */        wValue,
        /* wIndex */        wIndex,
        /* wLength */       static_cast<uint16_t>(len),
        /* data */          ctrlBuf_,
        /* bytesTransferred */ &bytesTransferred,
        /* completionTimeout */ GVM2TV_USB_TIMEOUT_MS);

    return ret;
}

kern_return_t GVM2TVUSBTransport::regRead(uint8_t addr, uint32_t reg,
                                          uint8_t *data, int len)
{
    if (!interface_ || !ctrlBuf_ || len <= 0 || len > CTRL_BUF_SIZE) {
        return kIOReturnBadArgument;
    }

    uint16_t wValue = (addr & 0xFF) | ((reg >> 8) & 0xF00);
    uint16_t wIndex = reg & 0xFFFF;

    uint16_t bytesTransferred = 0;
    kern_return_t ret = interface_->DeviceRequest(
        /* bmRequestType */ 0xC0,       /* Vendor, Device-to-Host */
        /* bRequest */      GVM2TV_BREQ_REG_RW,
        /* wValue */        wValue,
        /* wIndex */        wIndex,
        /* wLength */       static_cast<uint16_t>(len),
        /* data */          ctrlBuf_,
        /* bytesTransferred */ &bytesTransferred,
        /* completionTimeout */ GVM2TV_USB_TIMEOUT_MS);

    if (ret == kIOReturnSuccess) {
        uint64_t bufAddr = 0, bufLen = 0;
        ret = ctrlBuf_->Map(0, 0, 0, 0, &bufAddr, &bufLen);
        if (ret == kIOReturnSuccess) {
            memcpy(data, reinterpret_cast<const void *>(bufAddr), len);
        }
    }
    return ret;
}

/* ---- API Command ---- */

kern_return_t GVM2TVUSBTransport::setApiCmd(uint8_t *cmd6)
{
    if (!interface_ || !ctrlBuf_) return kIOReturnNotReady;

    /* Auto-increment sequence number */
    cmd6[1] = cmdSeq_;
    cmdSeq_ = (cmdSeq_ + 1 >= 0x3F) ? 0 : cmdSeq_ + 1;

    /* Copy to buffer */
    uint64_t bufAddr = 0, bufLen = 0;
    kern_return_t ret = ctrlBuf_->Map(0, 0, 0, 0, &bufAddr, &bufLen);
    if (ret != kIOReturnSuccess) return ret;
    memcpy(reinterpret_cast<void *>(bufAddr), cmd6, 6);

    uint16_t bytesTransferred = 0;
    return interface_->DeviceRequest(
        0x40, GVM2TV_BREQ_API_CMD,
        0x0000, 0x0000, 6,
        ctrlBuf_, &bytesTransferred, GVM2TV_USB_TIMEOUT_MS);
}

/* ---- Interrupt Transfer ---- */

int GVM2TVUSBTransport::getAck(uint8_t *buf, uint32_t timeout_ms)
{
    if (!ep3Pipe_) return -1;

    IOBufferMemoryDescriptor *intBuf = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionIn, 64, 0, &intBuf);
    if (ret != kIOReturnSuccess) return -1;

    uint32_t bytesTransferred = 0;
    ret = ep3Pipe_->IO(intBuf, 64, &bytesTransferred, 0);

    if (ret == kIOReturnSuccess && bytesTransferred > 0) {
        uint64_t addr = 0, len = 0;
        intBuf->Map(0, 0, 0, 0, &addr, &len);
        int copyLen = (bytesTransferred < 64) ? bytesTransferred : 64;
        memcpy(buf, reinterpret_cast<const void *>(addr), copyLen);
        OSSafeReleaseNULL(intBuf);
        return copyLen;
    }

    OSSafeReleaseNULL(intBuf);
    return (ret == kIOReturnTimeout) ? 0 : -1;
}

/* ---- I2C Proxy ---- */

kern_return_t GVM2TVUSBTransport::i2cWrite(const uint8_t *data, int len)
{
    if (!interface_ || !ctrlBuf_ || len <= 0) return kIOReturnBadArgument;

    /* Write I2C data: bReq=0xBD, wValue=0x0000, wIndex=0x1800 */
    uint64_t bufAddr = 0, bufLen = 0;
    kern_return_t ret = ctrlBuf_->Map(0, 0, 0, 0, &bufAddr, &bufLen);
    if (ret != kIOReturnSuccess) return ret;
    memcpy(reinterpret_cast<void *>(bufAddr), data, len);

    uint16_t bytesTransferred = 0;
    ret = interface_->DeviceRequest(
        0x40, GVM2TV_BREQ_I2C,
        0x0000, GVM2TV_I2C_WINDEX,
        static_cast<uint16_t>(len),
        ctrlBuf_, &bytesTransferred, GVM2TV_USB_TIMEOUT_MS);
    if (ret != kIOReturnSuccess) return ret;

    /* Confirmation read: wValue=0x000F, wIndex=0x1800 */
    uint16_t statusXfer = 0;
    interface_->DeviceRequest(
        0xC0, GVM2TV_BREQ_I2C,
        0x000F, GVM2TV_I2C_WINDEX,
        2, ctrlBuf_, &statusXfer, GVM2TV_USB_TIMEOUT_MS);

    return kIOReturnSuccess;
}

kern_return_t GVM2TVUSBTransport::i2cRead(uint8_t reg, uint8_t *buf, int len)
{
    if (!interface_ || !ctrlBuf_) return kIOReturnNotReady;

    uint64_t bufAddr = 0, bufLen = 0;
    kern_return_t ret = ctrlBuf_->Map(0, 0, 0, 0, &bufAddr, &bufLen);
    if (ret != kIOReturnSuccess) return ret;

    /* Phase 1: Write register address */
    uint8_t *mapped = reinterpret_cast<uint8_t *>(bufAddr);
    mapped[0] = reg;

    uint16_t xfer = 0;
    ret = interface_->DeviceRequest(
        0x40, GVM2TV_BREQ_I2C,
        0x0000, GVM2TV_I2C_WINDEX,
        1, ctrlBuf_, &xfer, GVM2TV_USB_TIMEOUT_MS);
    if (ret != kIOReturnSuccess) return ret;

    /* Confirmation read */
    interface_->DeviceRequest(
        0xC0, GVM2TV_BREQ_I2C,
        0x000F, GVM2TV_I2C_WINDEX,
        2, ctrlBuf_, &xfer, GVM2TV_USB_TIMEOUT_MS);

    /* Phase 2: Read data */
    ret = interface_->DeviceRequest(
        0xC0, GVM2TV_BREQ_I2C,
        0x0000, GVM2TV_I2C_WINDEX,
        static_cast<uint16_t>(len),
        ctrlBuf_, &xfer, GVM2TV_USB_TIMEOUT_MS);
    if (ret != kIOReturnSuccess) return ret;

    /* Copy result */
    ret = ctrlBuf_->Map(0, 0, 0, 0, &bufAddr, &bufLen);
    if (ret == kIOReturnSuccess) {
        memcpy(buf, reinterpret_cast<const void *>(bufAddr), len);
    }

    /* Final confirmation read */
    interface_->DeviceRequest(
        0xC0, GVM2TV_BREQ_I2C,
        0x000F, GVM2TV_I2C_WINDEX,
        2, ctrlBuf_, &xfer, GVM2TV_USB_TIMEOUT_MS);

    return kIOReturnSuccess;
}

kern_return_t GVM2TVUSBTransport::i2cWriteTable(const TunerI2CWriteData *tbl)
{
    int count = 0;
    while (tbl->count != 0) {
        kern_return_t ret = i2cWrite(tbl->data, tbl->count);
        if (ret != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT, LOG_PREFIX ": I2C table write failed at entry %d: 0x%x",
                   count, ret);
            return ret;
        }
        count++;
        tbl++;
    }
    return kIOReturnSuccess;
}

/* ---- Bulk Transfer ---- */

kern_return_t GVM2TVUSBTransport::uploadFirmware(const uint8_t *data, uint32_t len)
{
    if (!ep2Pipe_ || len < GVM2TV_FW_MAGIC_LEN) return kIOReturnBadArgument;

    /* Validate firmware header */
    if (memcmp(data, GVM2TV_FW_MAGIC, GVM2TV_FW_MAGIC_LEN) != 0) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": invalid firmware header");
        return kIOReturnBadArgument;
    }

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": uploading firmware (%u bytes)", len);

    /* Clear EP2 stall */
    ep2Pipe_->ClearStall(true);

    /* Allocate a buffer for bulk transfers */
    IOBufferMemoryDescriptor *fwBuf = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionOut, GVM2TV_FW_UPLOAD_CHUNK_SIZE, 0, &fwBuf);
    if (ret != kIOReturnSuccess) return ret;

    uint64_t fwAddr = 0, fwLen = 0;
    ret = fwBuf->Map(0, 0, 0, 0, &fwAddr, &fwLen);
    if (ret != kIOReturnSuccess) {
        OSSafeReleaseNULL(fwBuf);
        return ret;
    }

    uint32_t offset = 0;
    while (offset < len) {
        uint32_t chunkSize = (len - offset > GVM2TV_FW_UPLOAD_CHUNK_SIZE)
                            ? GVM2TV_FW_UPLOAD_CHUNK_SIZE
                            : (len - offset);

        memcpy(reinterpret_cast<void *>(fwAddr), data + offset, chunkSize);

        uint32_t bytesTransferred = 0;
        ret = ep2Pipe_->IO(fwBuf, chunkSize, &bytesTransferred, GVM2TV_USB_TIMEOUT_MS);
        if (ret != kIOReturnSuccess) {
            os_log(OS_LOG_DEFAULT, LOG_PREFIX ": FW upload failed at %u/%u: 0x%x",
                   offset, len, ret);
            OSSafeReleaseNULL(fwBuf);
            return ret;
        }
        offset += bytesTransferred;
    }

    OSSafeReleaseNULL(fwBuf);
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": firmware upload complete (%u bytes)", offset);
    return kIOReturnSuccess;
}

kern_return_t GVM2TVUSBTransport::bulkRead(uint8_t *buf, uint32_t len,
                                           uint32_t *transferred, uint32_t timeout_ms)
{
    if (!ep1Pipe_) return kIOReturnNotReady;

    IOBufferMemoryDescriptor *readBuf = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionIn, len, 0, &readBuf);
    if (ret != kIOReturnSuccess) return ret;

    *transferred = 0;
    ret = ep1Pipe_->IO(readBuf, len, transferred, timeout_ms);

    if (ret == kIOReturnSuccess && *transferred > 0) {
        uint64_t addr = 0, mapLen = 0;
        ret = readBuf->Map(0, 0, 0, 0, &addr, &mapLen);
        if (ret == kIOReturnSuccess) {
            memcpy(buf, reinterpret_cast<const void *>(addr), *transferred);
        }
    }

    OSSafeReleaseNULL(readBuf);
    return ret;
}

/* ---- High-Level Helpers ---- */

uint16_t GVM2TVUSBTransport::readDeviceState()
{
    uint8_t buf[2] = { 0xFF, 0xFF };
    kern_return_t ret = regRead(0, GVM2TV_REG_STATE, buf, 2);
    if (ret != kIOReturnSuccess) return kGVM2TVStateError;
    return static_cast<uint16_t>((buf[0] << 8) | buf[1]);
}

kern_return_t GVM2TVUSBTransport::waitInterruptReady()
{
    uint8_t buf[2];
    for (int i = 0; i < 101; i++) {
        kern_return_t ret = regRead(0, GVM2TV_REG_IRQ_STATUS, buf, 2);
        if (ret == kIOReturnSuccess && (buf[1] & 0x04)) {
            return kIOReturnSuccess;
        }
        IOSleep(2); /* 2ms */
    }
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": waitInterruptReady timeout");
    return kIOReturnTimeout;
}

kern_return_t GVM2TVUSBTransport::clearInterrupt()
{
    uint8_t data[] = { 0x00, 0x04 };
    return regWrite(0, GVM2TV_REG_IRQ_STATUS, data, 2);
}

kern_return_t GVM2TVUSBTransport::bootTrigger()
{
    uint8_t data[] = { 0x00, 0x04 };
    return regWrite(0, GVM2TV_REG_BOOT_TRIG, data, 2);
}

kern_return_t GVM2TVUSBTransport::clearHalt(uint8_t endpointAddr)
{
    IOUSBHostPipe *pipe = nullptr;
    switch (endpointAddr) {
    case GVM2TV_EP_BULK_IN1: pipe = ep1Pipe_; break;
    case GVM2TV_EP_BULK_OUT: pipe = ep2Pipe_; break;
    case GVM2TV_EP_INT_IN:   pipe = ep3Pipe_; break;
    case GVM2TV_EP_BULK_IN2: pipe = ep4Pipe_; break;
    default: return kIOReturnBadArgument;
    }
    if (!pipe) return kIOReturnNotFound;
    return pipe->ClearStall(true);
}
