#ifndef USBHelpers_h
#define USBHelpers_h

#include <CoreFoundation/CoreFoundation.h>

CF_RETURNS_NOT_RETAINED
CFUUIDRef GVM2TV_kIOUSBDeviceUserClientTypeID(void);

CF_RETURNS_NOT_RETAINED
CFUUIDRef GVM2TV_kIOCFPlugInInterfaceID(void);

CF_RETURNS_NOT_RETAINED
CFUUIDRef GVM2TV_kIOUSBDeviceInterfaceID(void);

CF_RETURNS_NOT_RETAINED
CFUUIDRef GVM2TV_kIOUSBInterfaceUserClientTypeID(void);

CF_RETURNS_NOT_RETAINED
CFUUIDRef GVM2TV_kIOUSBInterfaceInterfaceID(void);

#endif
