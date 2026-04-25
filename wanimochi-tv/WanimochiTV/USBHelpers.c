#include "USBHelpers.h"
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>

CFUUIDRef GVM2TV_kIOUSBDeviceUserClientTypeID(void) {
    return kIOUSBDeviceUserClientTypeID;
}

CFUUIDRef GVM2TV_kIOCFPlugInInterfaceID(void) {
    return kIOCFPlugInInterfaceID;
}

CFUUIDRef GVM2TV_kIOUSBDeviceInterfaceID(void) {
    return kIOUSBDeviceInterfaceID;
}

CFUUIDRef GVM2TV_kIOUSBInterfaceUserClientTypeID(void) {
    return kIOUSBInterfaceUserClientTypeID;
}

CFUUIDRef GVM2TV_kIOUSBInterfaceInterfaceID(void) {
    return kIOUSBInterfaceInterfaceID;
}
