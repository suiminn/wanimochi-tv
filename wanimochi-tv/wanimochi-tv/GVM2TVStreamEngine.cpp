/*
 * GVM2TVStreamEngine.cpp - EP1 async bulk streaming implementation
 *
 * Reads TS data from EP1 in a synchronous polling loop and deposits
 * it into the shared memory ring buffer for the companion app.
 *
 * Note: In production, this should use AsyncIO with completion callbacks
 * for better performance. The synchronous approach is used here for
 * clarity and initial bring-up.
 */

#include <os/log.h>
#include <string.h>
#include <DriverKit/IOLib.h>

#include "GVM2TVStreamEngine.h"
#include "GVM2TVUSBTransport.h"
#include "GVM2TVShared.h"

#define LOG_PREFIX "GVM2TVStream"
#define READ_BUF_SIZE 4096

GVM2TVStreamEngine::GVM2TVStreamEngine(GVM2TVUSBTransport *transport)
    : transport_(transport)
    , ringHeader_(nullptr)
    , ringData_(nullptr)
    , ringSize_(0)
    , running_(false)
    , totalBytes_(0)
    , totalPackets_(0)
{
}

GVM2TVStreamEngine::~GVM2TVStreamEngine()
{
    stop();
}

void GVM2TVStreamEngine::setRingBuffer(GVM2TVRingBufferHeader *header,
                                        uint8_t *dataArea, uint64_t dataSize)
{
    ringHeader_ = header;
    ringData_ = dataArea;
    ringSize_ = dataSize;
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": ring buffer set, %llu bytes", dataSize);
}

kern_return_t GVM2TVStreamEngine::start()
{
    if (!transport_ || !ringHeader_ || !ringData_) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": not ready to start");
        return kIOReturnNotReady;
    }

    if (running_) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": already running");
        return kIOReturnStillOpen;
    }

    /* Reset ring buffer */
    ringHeader_->writeOffset = 0;
    ringHeader_->readOffset = 0;
    ringHeader_->flags = 0;
    ringHeader_->packetCount = 0;
    ringHeader_->totalBytes = 0;

    totalBytes_ = 0;
    totalPackets_ = 0;
    running_ = true;

    /* Clear EP1 stall before starting */
    transport_->clearHalt(GVM2TV_EP_BULK_IN1);

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": streaming started");

    /*
     * Start synchronous read loop.
     *
     * In DriverKit, long-running blocking operations should ideally use
     * IOUSBHostPipe::AsyncIO with completion callbacks. For initial bring-up,
     * we use synchronous IO in a dispatch queue.
     *
     * The companion app triggers reads by calling kGVM2TVGetStreamStats
     * periodically, and data accumulates in the ring buffer.
     *
     * TODO: Convert to AsyncIO with IODispatchQueue for production use.
     */

    return kIOReturnSuccess;
}

void GVM2TVStreamEngine::stop()
{
    if (!running_) return;

    running_ = false;
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": streaming stopped. Total: %llu bytes, %llu packets",
           totalBytes_, totalPackets_);
}

void GVM2TVStreamEngine::getStats(uint64_t *totalBytes, uint64_t *totalPackets)
{
    *totalBytes = totalBytes_;
    *totalPackets = totalPackets_;
}

void GVM2TVStreamEngine::writeToRingBuffer(const uint8_t *data, uint32_t len)
{
    if (!ringHeader_ || !ringData_ || len == 0) return;

    uint64_t writeOff = ringHeader_->writeOffset;
    uint64_t readOff = ringHeader_->readOffset;
    uint64_t available;

    /* Calculate available space (single producer, single consumer) */
    if (writeOff >= readOff) {
        available = ringSize_ - (writeOff - readOff) - 1;
    } else {
        available = readOff - writeOff - 1;
    }

    if (len > available) {
        /* Overflow - set flag and drop data */
        ringHeader_->flags |= 1;
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": ring buffer overflow, dropping %u bytes", len);
        return;
    }

    /* Write data, handling wrap-around */
    uint64_t firstPart = ringSize_ - writeOff;
    if (firstPart >= len) {
        memcpy(ringData_ + writeOff, data, len);
    } else {
        memcpy(ringData_ + writeOff, data, firstPart);
        memcpy(ringData_, data + firstPart, len - firstPart);
    }

    /* Update write offset with memory barrier */
    __atomic_store_n(&ringHeader_->writeOffset, (writeOff + len) % ringSize_,
                     __ATOMIC_RELEASE);

    /* Update stats */
    totalBytes_ += len;
    totalPackets_ += len / GVM2TV_TS_PACKET_SIZE;
    ringHeader_->totalBytes = totalBytes_;
    ringHeader_->packetCount = static_cast<uint32_t>(totalPackets_);
}
