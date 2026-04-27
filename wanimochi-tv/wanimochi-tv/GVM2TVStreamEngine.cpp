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
#include <DriverKit/IODispatchQueue.h>

#include "GVM2TVStreamEngine.h"
#include "GVM2TVUSBTransport.h"
#include "GVM2TVShared.h"

#define LOG_PREFIX "GVM2TVStream"
#define READ_BUF_SIZE 4096

GVM2TVStreamEngine::GVM2TVStreamEngine(GVM2TVUSBTransport *transport)
    : transport_(transport)
    , readQueue_(nullptr)
    , ringHeader_(nullptr)
    , ringData_(nullptr)
    , ringSize_(0)
    , running_(false)
    , readerScheduled_(false)
    , readerActive_(false)
    , totalBytes_(0)
    , totalPackets_(0)
{
}

GVM2TVStreamEngine::~GVM2TVStreamEngine()
{
    stop();
    OSSafeReleaseNULL(readQueue_);
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

    if (!readQueue_) {
        kern_return_t ret = IODispatchQueue::Create("GVM2TVStreamReader", 0, 0, &readQueue_);
        if (ret != kIOReturnSuccess) {
            running_ = false;
            os_log(OS_LOG_DEFAULT, LOG_PREFIX ": read queue create failed: 0x%x", ret);
            return ret;
        }
    }

    readerScheduled_ = true;
    readerActive_ = false;
    readQueue_->DispatchAsync_f(this, &GVM2TVStreamEngine::readLoopThunk);

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": streaming started");

    return kIOReturnSuccess;
}

void GVM2TVStreamEngine::stop()
{
    if (!running_) return;

    running_ = false;
    for (int i = 0; (readerScheduled_ || readerActive_) && i < 200; i++) {
        IOSleep(10);
    }

    if (readerScheduled_ || readerActive_) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": read loop did not stop before timeout");
    }

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": streaming stopped. Total: %llu bytes, %llu packets",
           totalBytes_, totalPackets_);
}

void GVM2TVStreamEngine::getStats(uint64_t *totalBytes, uint64_t *totalPackets)
{
    *totalBytes = totalBytes_;
    *totalPackets = totalPackets_;
}

void GVM2TVStreamEngine::readLoopThunk(void *context)
{
    GVM2TVStreamEngine *engine = static_cast<GVM2TVStreamEngine *>(context);
    if (engine) {
        engine->readLoop();
    }
}

void GVM2TVStreamEngine::readLoop()
{
    readerActive_ = true;

    uint8_t *buffer = IONew(uint8_t, READ_BUF_SIZE);
    if (!buffer) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": read buffer alloc failed");
        running_ = false;
        readerActive_ = false;
        readerScheduled_ = false;
        return;
    }

    while (running_) {
        uint32_t transferred = 0;
        kern_return_t ret = transport_->bulkRead(buffer, READ_BUF_SIZE, &transferred, 100);
        if (ret == kIOReturnSuccess && transferred > 0) {
            writeToRingBuffer(buffer, transferred);
            continue;
        }

        if (ret == kIOReturnTimeout || transferred == 0) {
            continue;
        }

        if (running_) {
            os_log(OS_LOG_DEFAULT, LOG_PREFIX ": EP1 read failed: 0x%x", ret);
            IOSleep(10);
        }
    }

    IODelete(buffer, uint8_t, READ_BUF_SIZE);
    readerActive_ = false;
    readerScheduled_ = false;
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
