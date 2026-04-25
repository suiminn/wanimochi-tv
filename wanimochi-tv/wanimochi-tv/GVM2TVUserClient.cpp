/*
 * GVM2TVUserClient.cpp - IOUserClient implementation for GV-M2TV
 *
 * Dispatches ExternalMethod calls from the companion app to the appropriate
 * DEXT subsystem (transport, tuner, stream engine).
 */

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSData.h>

#include "GVM2TVUserClient.h"
#include "GVM2TVUSBTransport.h"
#include "GVM2TVTuner.h"
#include "GVM2TVStreamEngine.h"
#include "GVM2TVShared.h"

struct GVM2TVUserClient_IVars {
    GVM2TVUSBTransport  *transport;
    GVM2TVTuner         *tuner;
    GVM2TVStreamEngine  *streamEngine;
    IOBufferMemoryDescriptor *ringBufferDesc;
    GVM2TVRingBufferHeader   *ringBufferHeader;
};

#define LOG_PREFIX "GVM2TVUserClient"

bool GVM2TVUserClient::init()
{
    if (!super::init()) return false;

    ivars = IONewZero(GVM2TVUserClient_IVars, 1);
    if (!ivars) return false;

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": init");
    return true;
}

void GVM2TVUserClient::free()
{
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": free");

    if (ivars) {
        OSSafeReleaseNULL(ivars->ringBufferDesc);
        IODelete(ivars, GVM2TVUserClient_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

kern_return_t IMPL(GVM2TVUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Start");

    /* Allocate shared memory ring buffer for TS streaming */
    uint64_t totalSize = GVM2TV_RING_BUFFER_HEADER_SIZE + GVM2TV_RING_BUFFER_SIZE;
    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, totalSize, 0, &ivars->ringBufferDesc);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": ring buffer alloc failed: 0x%x", ret);
        return ret;
    }

    /* Map ring buffer into our address space */
    uint64_t address = 0;
    uint64_t length = 0;
    ret = ivars->ringBufferDesc->Map(0, 0, 0, 0, &address, &length);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": ring buffer map failed: 0x%x", ret);
        return ret;
    }

    /* Initialize ring buffer header */
    ivars->ringBufferHeader = reinterpret_cast<GVM2TVRingBufferHeader *>(address);
    ivars->ringBufferHeader->writeOffset = 0;
    ivars->ringBufferHeader->readOffset = 0;
    ivars->ringBufferHeader->bufferSize = GVM2TV_RING_BUFFER_SIZE;
    ivars->ringBufferHeader->flags = 0;
    ivars->ringBufferHeader->packetCount = 0;
    ivars->ringBufferHeader->totalBytes = 0;

    /* Pass ring buffer to stream engine */
    if (ivars->streamEngine) {
        ivars->streamEngine->setRingBuffer(
            ivars->ringBufferHeader,
            reinterpret_cast<uint8_t *>(address + GVM2TV_RING_BUFFER_HEADER_SIZE),
            GVM2TV_RING_BUFFER_SIZE);
    }

    return kIOReturnSuccess;
}

kern_return_t IMPL(GVM2TVUserClient, Stop)
{
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Stop");
    return Stop(provider, SUPERDISPATCH);
}

void GVM2TVUserClient::setTransport(GVM2TVUSBTransport *transport)
{
    if (ivars) ivars->transport = transport;
}

void GVM2TVUserClient::setTuner(GVM2TVTuner *tuner)
{
    if (ivars) ivars->tuner = tuner;
}

void GVM2TVUserClient::setStreamEngine(GVM2TVStreamEngine *engine)
{
    if (ivars) ivars->streamEngine = engine;
}

/* ---- Shared Memory ---- */

kern_return_t IMPL(GVM2TVUserClient, CopyClientMemoryForType)
{
    if (type == GVM2TV_MEMORY_TYPE_RING_BUFFER) {
        if (!ivars->ringBufferDesc) return kIOReturnNotReady;
        ivars->ringBufferDesc->retain();
        *memory = ivars->ringBufferDesc;
        *options = 0;
        return kIOReturnSuccess;
    }
    return kIOReturnBadArgument;
}

/* ---- ExternalMethod Dispatch ---- */

kern_return_t GVM2TVUserClient::ExternalMethod(uint64_t selector, IOUserClientMethodArguments *arguments, const IOUserClientMethodDispatch *dispatch, OSObject *target, void *reference)
{
    if (!ivars || !ivars->transport) {
        return kIOReturnNotReady;
    }

    switch (selector) {

    /* ---- Device Lifecycle ---- */

    case kGVM2TVGetDeviceState: {
        uint16_t state = ivars->transport->readDeviceState();
        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = state;
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVUploadFirmware: {
        if (arguments->structureInputDescriptor) {
            /* Large firmware data via memory descriptor */
            uint64_t addr = 0, len = 0;
            kern_return_t ret = arguments->structureInputDescriptor->Map(0, 0, 0, 0, &addr, &len);
            if (ret != kIOReturnSuccess) return ret;
            return ivars->transport->uploadFirmware(
                reinterpret_cast<const uint8_t *>(addr), static_cast<uint32_t>(len));
        } else if (arguments->structureInput) {
            /* Small firmware data via OSData */
            const void *data = arguments->structureInput->getBytesNoCopy();
            size_t len = arguments->structureInput->getLength();
            if (!data || len == 0) return kIOReturnBadArgument;
            return ivars->transport->uploadFirmware(
                reinterpret_cast<const uint8_t *>(data), static_cast<uint32_t>(len));
        }
        return kIOReturnBadArgument;
    }

    case kGVM2TVBootTrigger: {
        return ivars->transport->bootTrigger();
    }

    case kGVM2TVWaitStateChange: {
        kern_return_t ret = ivars->transport->waitInterruptReady();
        if (ret != kIOReturnSuccess) return ret;
        uint16_t state = ivars->transport->readDeviceState();
        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = state;
        }
        return kIOReturnSuccess;
    }

    /* ---- Register Access ---- */

    case kGVM2TVRegisterWrite: {
        if (arguments->scalarInputCount < 1 || !arguments->structureInput)
            return kIOReturnBadArgument;
        uint32_t reg = static_cast<uint32_t>(arguments->scalarInput[0]);
        const void *inData = arguments->structureInput->getBytesNoCopy();
        size_t inLen = arguments->structureInput->getLength();
        if (!inData || inLen == 0) return kIOReturnBadArgument;
        return ivars->transport->regWrite(0, reg,
            reinterpret_cast<const uint8_t *>(inData), static_cast<int>(inLen));
    }

    case kGVM2TVRegisterRead: {
        if (arguments->scalarInputCount < 2 || !arguments->structureOutputDescriptor)
            return kIOReturnBadArgument;
        uint32_t reg = static_cast<uint32_t>(arguments->scalarInput[0]);
        int readLen = static_cast<int>(arguments->scalarInput[1]);
        uint64_t addr = 0, len = 0;
        kern_return_t ret = arguments->structureOutputDescriptor->Map(0, 0, 0, 0, &addr, &len);
        if (ret != kIOReturnSuccess) return ret;
        if (readLen > static_cast<int>(len)) readLen = static_cast<int>(len);
        return ivars->transport->regRead(0, reg,
            reinterpret_cast<uint8_t *>(addr), readLen);
    }

    case kGVM2TVSendApiCommand: {
        if (!arguments->structureInput) return kIOReturnBadArgument;
        const void *inData = arguments->structureInput->getBytesNoCopy();
        size_t inLen = arguments->structureInput->getLength();
        if (!inData || inLen < 6) return kIOReturnBadArgument;

        uint8_t cmd[6];
        memcpy(cmd, inData, 6);
        kern_return_t ret = ivars->transport->setApiCmd(cmd);
        if (ret != kIOReturnSuccess) return ret;

        /* Return ACK if output buffer provided */
        if (arguments->structureOutputDescriptor) {
            uint64_t outAddr = 0, outLen = 0;
            ret = arguments->structureOutputDescriptor->Map(0, 0, 0, 0, &outAddr, &outLen);
            if (ret == kIOReturnSuccess && outLen >= 6) {
                memcpy(reinterpret_cast<void *>(outAddr), cmd, 6);
            }
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVGetInterruptMessage: {
        if (!arguments->structureOutputDescriptor) return kIOReturnBadArgument;
        uint32_t timeout_ms = 3000;
        if (arguments->scalarInputCount >= 1) {
            timeout_ms = static_cast<uint32_t>(arguments->scalarInput[0]);
        }
        uint64_t outAddr = 0, outLen = 0;
        kern_return_t ret = arguments->structureOutputDescriptor->Map(0, 0, 0, 0, &outAddr, &outLen);
        if (ret != kIOReturnSuccess) return ret;

        uint8_t buf[64] = {};
        int n = ivars->transport->getAck(buf, timeout_ms);
        if (n <= 0) return kIOReturnTimeout;

        int copyLen = (n < static_cast<int>(outLen)) ? n : static_cast<int>(outLen);
        memcpy(reinterpret_cast<void *>(outAddr), buf, copyLen);
        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = n;
        }
        return kIOReturnSuccess;
    }

    /* ---- Secure Register Access ---- */

    case kGVM2TVSecureRegWrite: {
        if (arguments->scalarInputCount < 1 || !arguments->structureInput)
            return kIOReturnBadArgument;
        uint32_t baseReg = static_cast<uint32_t>(arguments->scalarInput[0]);
        const uint8_t *data = reinterpret_cast<const uint8_t *>(
            arguments->structureInput->getBytesNoCopy());
        size_t len = arguments->structureInput->getLength();
        if (!data || len == 0) return kIOReturnBadArgument;

        /* Write in 64-byte chunks */
        uint32_t offset = 0;
        while (offset < len) {
            int chunk = ((len - offset) > 64) ? 64 : static_cast<int>(len - offset);
            kern_return_t ret = ivars->transport->regWrite(0, baseReg + offset, data + offset, chunk);
            if (ret != kIOReturnSuccess) return ret;
            offset += chunk;
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVSecureRegRead: {
        if (arguments->scalarInputCount < 2 || !arguments->structureOutputDescriptor)
            return kIOReturnBadArgument;
        uint32_t baseReg = static_cast<uint32_t>(arguments->scalarInput[0]);
        int readLen = static_cast<int>(arguments->scalarInput[1]);
        uint64_t addr = 0, len = 0;
        kern_return_t ret = arguments->structureOutputDescriptor->Map(0, 0, 0, 0, &addr, &len);
        if (ret != kIOReturnSuccess) return ret;
        if (readLen > static_cast<int>(len)) readLen = static_cast<int>(len);

        uint8_t *data = reinterpret_cast<uint8_t *>(addr);
        uint32_t offset = 0;
        while (offset < static_cast<uint32_t>(readLen)) {
            int chunk = ((readLen - offset) > 64) ? 64 : static_cast<int>(readLen - offset);
            ret = ivars->transport->regRead(0, baseReg + offset, data + offset, chunk);
            if (ret != kIOReturnSuccess) return ret;
            offset += chunk;
        }
        return kIOReturnSuccess;
    }

    /* ---- B-CAS Relay ---- */

    case kGVM2TVBCASRegWrite: {
        if (arguments->scalarInputCount < 1 || !arguments->structureInput)
            return kIOReturnBadArgument;
        uint32_t reg = static_cast<uint32_t>(arguments->scalarInput[0]);
        const uint8_t *data = reinterpret_cast<const uint8_t *>(
            arguments->structureInput->getBytesNoCopy());
        size_t len = arguments->structureInput->getLength();
        if (!data || len == 0) return kIOReturnBadArgument;

        uint32_t offset = 0;
        while (offset < len) {
            int chunk = ((len - offset) > 64) ? 64 : static_cast<int>(len - offset);
            kern_return_t ret = ivars->transport->regWrite(0, reg + offset, data + offset, chunk);
            if (ret != kIOReturnSuccess) return ret;
            offset += chunk;
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVBCASRegRead: {
        if (arguments->scalarInputCount < 2 || !arguments->structureOutputDescriptor)
            return kIOReturnBadArgument;
        uint32_t reg = static_cast<uint32_t>(arguments->scalarInput[0]);
        int readLen = static_cast<int>(arguments->scalarInput[1]);
        uint64_t addr = 0, len = 0;
        kern_return_t ret = arguments->structureOutputDescriptor->Map(0, 0, 0, 0, &addr, &len);
        if (ret != kIOReturnSuccess) return ret;
        if (readLen > static_cast<int>(len)) readLen = static_cast<int>(len);

        uint8_t *data = reinterpret_cast<uint8_t *>(addr);
        uint32_t offset = 0;
        while (offset < static_cast<uint32_t>(readLen)) {
            int chunk = ((readLen - offset) > 64) ? 64 : static_cast<int>(readLen - offset);
            ret = ivars->transport->regRead(0, reg + offset, data + offset, chunk);
            if (ret != kIOReturnSuccess) return ret;
            offset += chunk;
        }
        return kIOReturnSuccess;
    }

    /* ---- Tuner Control ---- */

    case kGVM2TVTunerInit: {
        if (!ivars->tuner) return kIOReturnNotReady;
        return ivars->tuner->initTuner();
    }

    case kGVM2TVTunerTune: {
        if (!ivars->tuner || arguments->scalarInputCount < 1)
            return kIOReturnBadArgument;
        int channel = static_cast<int>(arguments->scalarInput[0]);
        bool locked = false;
        kern_return_t ret = ivars->tuner->tune(channel, &locked);
        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = locked ? 1 : 0;
        }
        return ret;
    }

    case kGVM2TVTunerGetSignal: {
        if (!ivars->tuner) return kIOReturnNotReady;
        int strength = ivars->tuner->getSignalStrength();
        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = strength;
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVTunerSleep: {
        if (!ivars->tuner) return kIOReturnNotReady;
        return ivars->tuner->sleep();
    }

    /* ---- Transcode Firmware ---- */

    case kGVM2TVClearTRCRegisters: {
        uint8_t zero[2] = { 0x00, 0x00 };
        for (uint32_t reg = 0x1000; reg < 0x1500; reg += 2) {
            kern_return_t ret = ivars->transport->regWrite(0, reg, zero, 2);
            if (ret != kIOReturnSuccess) return ret;
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVWriteTRCParameters: {
        for (size_t i = 0; i < GVM2TV_TRC_PARAM_COUNT; i++) {
            uint8_t val[2] = { kGVM2TVDefaultTRCParams[i].hi, kGVM2TVDefaultTRCParams[i].lo };
            kern_return_t ret = ivars->transport->regWrite(
                0, kGVM2TVDefaultTRCParams[i].reg, val, 2);
            if (ret != kIOReturnSuccess) return ret;
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVUploadTRCFirmware: {
        /* Same as kGVM2TVUploadFirmware - reuse upload logic */
        if (arguments->structureInputDescriptor) {
            uint64_t addr = 0, len = 0;
            kern_return_t ret = arguments->structureInputDescriptor->Map(0, 0, 0, 0, &addr, &len);
            if (ret != kIOReturnSuccess) return ret;
            return ivars->transport->uploadFirmware(
                reinterpret_cast<const uint8_t *>(addr), static_cast<uint32_t>(len));
        } else if (arguments->structureInput) {
            const void *data = arguments->structureInput->getBytesNoCopy();
            size_t len = arguments->structureInput->getLength();
            if (!data || len == 0) return kIOReturnBadArgument;
            return ivars->transport->uploadFirmware(
                reinterpret_cast<const uint8_t *>(data), static_cast<uint32_t>(len));
        }
        return kIOReturnBadArgument;
    }

    case kGVM2TVActivateTranscoder: {
        /* cmd 0x04 byte[3]=0x00 → upload mode */
        uint8_t cmd1[6] = { 0x00, 0x00, 0x04, 0x00, 0x00, 0x00 };
        kern_return_t ret = ivars->transport->setApiCmd(cmd1);
        if (ret != kIOReturnSuccess) return ret;

        uint8_t ack[64];
        ivars->transport->getAck(ack, 1000);

        /* cmd 0x04 byte[3]=0x20 → activate */
        uint8_t cmd2[6] = { 0x00, 0x00, 0x04, 0x20, 0x00, 0x00 };
        ret = ivars->transport->setApiCmd(cmd2);
        if (ret != kIOReturnSuccess) return ret;

        /* Wait for STATE_CHANGE (0x20) on EP3 */
        for (int i = 0; i < 20; i++) {
            int n = ivars->transport->getAck(ack, 500);
            if (n > 0 && ack[0] == 0x20) break;
        }

        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = ivars->transport->readDeviceState();
        }
        return kIOReturnSuccess;
    }

    /* ---- Streaming ---- */

    case kGVM2TVStartStreaming: {
        if (!ivars->streamEngine) return kIOReturnNotReady;

        /* Send GPIO START command */
        uint8_t startCmd[6] = { 0x00, 0x00, 0x05, 0x00, 0x00, 0x02 };
        kern_return_t ret = ivars->transport->setApiCmd(startCmd);
        if (ret != kIOReturnSuccess) return ret;

        /* Wait for STATE_CHANGE */
        uint8_t ack[64];
        for (int i = 0; i < 10; i++) {
            int n = ivars->transport->getAck(ack, 1000);
            if (n > 0 && ack[0] == 0x20) break;
        }

        /* Start async EP1 reads */
        return ivars->streamEngine->start();
    }

    case kGVM2TVStopStreaming: {
        if (!ivars->streamEngine) return kIOReturnNotReady;

        /* Stop streaming engine */
        ivars->streamEngine->stop();

        /* Two-phase stop: TS disable + tuner sleep + GPIO stop */
        if (ivars->tuner) {
            ivars->tuner->sleep();
        }

        /* GPIO STOP command */
        uint8_t stopCmd[6] = { 0x00, 0x00, 0x05, 0x00, 0x00, 0x04 };
        ivars->transport->setApiCmd(stopCmd);
        uint8_t ack[64];
        ivars->transport->getAck(ack, 1000);

        /* GPIO SLEEP command */
        uint8_t sleepCmd[6] = { 0x00, 0x00, 0x05, 0x00, 0x00, 0x01 };
        ivars->transport->setApiCmd(sleepCmd);
        ivars->transport->getAck(ack, 1000);

        /* FORCE_RESET to return to Secure/IDLE */
        uint8_t resetCmd[6] = { 0x00, 0x00, 0x0F, 0x00, 0x00, 0x00 };
        ivars->transport->setApiCmd(resetCmd);
        ivars->transport->getAck(ack, 2000);

        if (arguments->scalarOutputCount >= 1) {
            arguments->scalarOutput[0] = ivars->transport->readDeviceState();
        }
        return kIOReturnSuccess;
    }

    case kGVM2TVGetStreamStats: {
        if (!ivars->streamEngine) return kIOReturnNotReady;
        uint64_t bytes = 0, packets = 0;
        ivars->streamEngine->getStats(&bytes, &packets);
        if (arguments->scalarOutputCount >= 1) arguments->scalarOutput[0] = bytes;
        if (arguments->scalarOutputCount >= 2) arguments->scalarOutput[1] = packets;
        return kIOReturnSuccess;
    }

    /* ---- GPIO ---- */

    case kGVM2TVSetGPIO: {
        uint8_t gpioCnt[] = { 0x02, 0xF4 };
        kern_return_t ret = ivars->transport->regWrite(0, GVM2TV_REG_GPIO_CNT, gpioCnt, 2);
        if (ret != kIOReturnSuccess) return ret;
        uint8_t gpioOut[] = { 0x03, 0xFF };
        return ivars->transport->regWrite(0, GVM2TV_REG_GPIO_OUT, gpioOut, 2);
    }

    /* ---- Endpoint Management ---- */

    case kGVM2TVClearEndpointHalt: {
        if (arguments->scalarInputCount < 1) return kIOReturnBadArgument;
        uint8_t ep = static_cast<uint8_t>(arguments->scalarInput[0]);
        return ivars->transport->clearHalt(ep);
    }

    default:
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": unknown selector %llu", selector);
        return kIOReturnBadArgument;
    }
}
