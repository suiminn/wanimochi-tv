/*
 * GVM2TVDriver.cpp - IOService implementation for I-O DATA GV-M2TV
 *
 * Opens the USB interface, creates pipes for all endpoints, and manages
 * the device lifecycle. Delegates all USB I/O to GVM2TVUSBTransport.
 */

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <USBDriverKit/IOUSBHostInterface.h>
#include <USBDriverKit/IOUSBHostPipe.h>

#include "GVM2TVDriver.h"
#include "GVM2TVUserClient.h"
#include "GVM2TVUSBTransport.h"
#include "GVM2TVTuner.h"
#include "GVM2TVStreamEngine.h"
#include "GVM2TVShared.h"

struct GVM2TVDriver_IVars {
    IOUSBHostInterface *interface;
    GVM2TVUSBTransport *transport;
    GVM2TVTuner        *tuner;
    GVM2TVStreamEngine *streamEngine;
    uint16_t            deviceState;
};

#define LOG_PREFIX "GVM2TVDriver"

bool GVM2TVDriver::init()
{
    if (!super::init()) {
        return false;
    }

    ivars = IONewZero(GVM2TVDriver_IVars, 1);
    if (!ivars) {
        return false;
    }

    ivars->deviceState = kGVM2TVStateError;
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": init");
    return true;
}

void GVM2TVDriver::free()
{
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": free");

    if (ivars) {
        if (ivars->streamEngine) {
            delete ivars->streamEngine;
            ivars->streamEngine = nullptr;
        }
        if (ivars->tuner) {
            delete ivars->tuner;
            ivars->tuner = nullptr;
        }
        if (ivars->transport) {
            delete ivars->transport;
            ivars->transport = nullptr;
        }
        OSSafeReleaseNULL(ivars->interface);
        IODelete(ivars, GVM2TVDriver_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

kern_return_t IMPL(GVM2TVDriver, Start)
{
    kern_return_t ret;

    ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": super::Start failed: 0x%x", ret);
        return ret;
    }

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Start - opening USB interface");

    /* Get the IOUSBHostInterface provider */
    ivars->interface = OSDynamicCast(IOUSBHostInterface, provider);
    if (!ivars->interface) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": provider is not IOUSBHostInterface");
        return kIOReturnNotFound;
    }
    ivars->interface->retain();

    /* Open the interface */
    ret = ivars->interface->Open(this, 0, nullptr);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Open interface failed: 0x%x", ret);
        return ret;
    }

    /* Create USB transport layer */
    ivars->transport = new GVM2TVUSBTransport();
    ret = ivars->transport->init(ivars->interface);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": transport init failed: 0x%x", ret);
        return ret;
    }

    /* Create tuner controller */
    ivars->tuner = new GVM2TVTuner(ivars->transport);

    /* Create stream engine */
    ivars->streamEngine = new GVM2TVStreamEngine(ivars->transport);

    /* Read initial device state */
    ivars->deviceState = ivars->transport->readDeviceState();
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": device state = 0x%04x", ivars->deviceState);

    /* Register the service so IOUserClient can find us */
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": RegisterService failed: 0x%x", ret);
        return ret;
    }

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Start complete, device state = 0x%04x",
           ivars->deviceState);
    return kIOReturnSuccess;
}

kern_return_t IMPL(GVM2TVDriver, Stop)
{
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Stop");

    /* Stop streaming if active */
    if (ivars && ivars->streamEngine) {
        ivars->streamEngine->stop();
    }

    /* Close the interface */
    if (ivars && ivars->interface) {
        ivars->interface->Close(this, 0);
    }

    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(GVM2TVDriver, NewUserClient)
{
    kern_return_t ret;
    IOService *client = nullptr;

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": NewUserClient type=%u", type);

    ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": Create UserClient failed: 0x%x", ret);
        return ret;
    }

    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": cast to IOUserClient failed");
        client->release();
        return kIOReturnError;
    }

    /* Pass our internal references to the UserClient */
    GVM2TVUserClient *uc = OSDynamicCast(GVM2TVUserClient, *userClient);
    if (uc) {
        uc->setTransport(ivars->transport);
        uc->setTuner(ivars->tuner);
        uc->setStreamEngine(ivars->streamEngine);
    }

    return kIOReturnSuccess;
}
