/*
 * GVM2TVShared.h - Shared definitions between DEXT and Companion App
 *
 * I-O DATA GV-M2TV (USB VID:PID = 04bb:053a)
 * Fujitsu MB86H57 + MJ111 ISDB-T Tuner/Demodulator
 */

#ifndef GVM2TV_SHARED_H
#define GVM2TV_SHARED_H

#include <stdint.h>

/* ---- USB Device Identifiers ---- */

#define GVM2TV_VENDOR_ID   0x04BB
#define GVM2TV_PRODUCT_ID  0x053A

/* ---- USB Endpoints ---- */

#define GVM2TV_EP_BULK_IN1  0x81  /* TS stream data */
#define GVM2TV_EP_BULK_OUT  0x02  /* FW/command upload */
#define GVM2TV_EP_INT_IN    0x83  /* ACK/status messages */
#define GVM2TV_EP_BULK_IN2  0x84  /* Sub-stream (1-seg, unused) */

/* ---- USB Request Types ---- */

#define GVM2TV_BREQ_API_CMD  0xB8  /* API command */
#define GVM2TV_BREQ_REG_RW   0xBC  /* Register read/write */
#define GVM2TV_BREQ_I2C      0xBD  /* I2C proxy (MJ111) */

/* ---- MB86H57 Registers ---- */

#define GVM2TV_REG_STATE       0x82008  /* Device state (2 bytes) */
#define GVM2TV_REG_BOOT_TRIG   0x90070  /* Boot trigger after FW upload */
#define GVM2TV_REG_IRQ_STATUS  0x90074  /* Interrupt status */
#define GVM2TV_REG_IRQ_ENABLE  0x90078  /* Interrupt enable */
#define GVM2TV_REG_CHIP_ID     0x90004  /* Chip ID */
#define GVM2TV_REG_SECURE_BASE 0x83000  /* Secure command register base */
#define GVM2TV_REG_GPIO_CNT    0x90014  /* GPIO control count */
#define GVM2TV_REG_GPIO_OUT    0x90018  /* GPIO output */
#define GVM2TV_REG_BCAS_CMD    0x8219C  /* B-CAS command register */
#define GVM2TV_REG_BCAS_STATE  0x822AC  /* B-CAS state register */
#define GVM2TV_REG_BCAS_RESP   0x822AE  /* B-CAS response register */

/* ---- Device States ---- */

enum GVM2TVDeviceState : uint16_t {
    kGVM2TVStateNoFirm   = 0x0000,  /* No firmware loaded */
    kGVM2TVStateTranscode = 0x0001,  /* Transcode mode (TRC FW active) */
    kGVM2TVStateSecure    = 0x0010,  /* Secure mode (after FW boot) */
    kGVM2TVStateIdle      = 0x0011,  /* Idle (authenticated, ready) */
    kGVM2TVStateSleep     = 0x0012,  /* Sleep mode */
    kGVM2TVStateError     = 0xFFFF,  /* Communication error */
};

/* ---- I2C Constants ---- */

#define GVM2TV_I2C_DEMOD_ADDR  0x30
#define GVM2TV_I2C_WINDEX      0x1800  /* (0x30 << 7) & 0x3F00 */

/* ---- IOUserClient External Method Selectors ---- */

enum GVM2TVSelector : uint64_t {
    /* Device lifecycle */
    kGVM2TVGetDeviceState      = 0,   /* out: scalar[0] = state */
    kGVM2TVUploadFirmware      = 1,   /* in: structInput = FW binary data */
    kGVM2TVBootTrigger         = 2,   /* trigger FW boot */
    kGVM2TVWaitStateChange     = 3,   /* out: scalar[0] = new state */

    /* Register access (for app-side secure auth) */
    kGVM2TVRegisterWrite       = 10,  /* in: scalar[0]=reg, structInput=data */
    kGVM2TVRegisterRead        = 11,  /* in: scalar[0]=reg, scalar[1]=len; out: structOutput=data */
    kGVM2TVSendApiCommand      = 12,  /* in: structInput=6-byte cmd; out: structOutput=ack */
    kGVM2TVGetInterruptMessage = 13,  /* in: scalar[0]=timeout_ms; out: structOutput=data */

    /* Secure command relay (512-byte register-mapped) */
    kGVM2TVSecureRegWrite      = 20,  /* in: scalar[0]=base_reg, structInput=data (up to 512B) */
    kGVM2TVSecureRegRead       = 21,  /* in: scalar[0]=base_reg, scalar[1]=len; out: structOutput */

    /* B-CAS relay */
    kGVM2TVBCASRegWrite        = 25,  /* in: scalar[0]=reg, structInput=data */
    kGVM2TVBCASRegRead         = 26,  /* in: scalar[0]=reg, scalar[1]=len; out: structOutput */

    /* Tuner control (runs entirely in DEXT) */
    kGVM2TVTunerInit           = 30,  /* initialize MJ111 via I2C */
    kGVM2TVTunerTune           = 31,  /* in: scalar[0]=channel; out: scalar[0]=locked */
    kGVM2TVTunerGetSignal      = 32,  /* out: scalar[0]=strength (0-100) */
    kGVM2TVTunerSleep          = 33,  /* put tuner to sleep */

    /* Transcode firmware */
    kGVM2TVClearTRCRegisters   = 40,  /* clear 0x1000-0x14FE */
    kGVM2TVWriteTRCParameters  = 41,  /* write PID filter config */
    kGVM2TVUploadTRCFirmware   = 42,  /* in: structInput = TRC FW data */
    kGVM2TVActivateTranscoder  = 43,  /* send cmd 0x04 sequence */

    /* Streaming */
    kGVM2TVStartStreaming      = 50,  /* start EP1 reads + START cmd */
    kGVM2TVStopStreaming       = 51,  /* two-phase stop, drain, return to IDLE */
    kGVM2TVGetStreamStats      = 52,  /* out: scalar[0]=bytes, scalar[1]=packets */

    /* GPIO */
    kGVM2TVSetGPIO             = 60,  /* write GPIO registers */

    /* Endpoint management */
    kGVM2TVClearEndpointHalt   = 70,  /* in: scalar[0]=endpoint_addr */

    kGVM2TVSelectorCount
};

/* ---- Shared Memory Ring Buffer ---- */

#define GVM2TV_RING_BUFFER_SIZE       (4 * 1024 * 1024)  /* 4 MB data area */
#define GVM2TV_RING_BUFFER_HEADER_SIZE 64                 /* Header page size */

struct GVM2TVRingBufferHeader {
    volatile uint64_t writeOffset;   /* DEXT writes here (atomic) */
    volatile uint64_t readOffset;    /* App writes here (atomic) */
    uint64_t          bufferSize;    /* Total data area size */
    uint32_t          flags;         /* Bit 0: overflow occurred */
    uint32_t          packetCount;   /* Total TS packets written */
    uint64_t          totalBytes;    /* Total bytes written */
    uint32_t          reserved[6];
};

/* Shared memory type for CopyClientMemoryForType */
#define GVM2TV_MEMORY_TYPE_RING_BUFFER 0

/* ---- Firmware Header ---- */

#define GVM2TV_FW_MAGIC "MB8AC018"
#define GVM2TV_FW_MAGIC_LEN 8
#define GVM2TV_FW_UPLOAD_CHUNK_SIZE 512

/* ---- TS Constants ---- */

#define GVM2TV_TS_PACKET_SIZE  188
#define GVM2TV_TS_SYNC_BYTE   0x47

/* ---- Timeout ---- */

#define GVM2TV_USB_TIMEOUT_MS  3000

/* ---- Transcode Parameters ---- */

struct GVM2TVTRCParam {
    uint32_t reg;
    uint8_t  hi;
    uint8_t  lo;
};

static const struct GVM2TVTRCParam kGVM2TVDefaultTRCParams[] = {
    { 0x1002, 0x84, 0x04 },
    { 0x1004, 0x01, 0x84 },
    { 0x100a, 0x00, 0x20 },
    { 0x100c, 0x00, 0x10 },
    { 0x101a, 0xB3, 0x00 },
    { 0x101c, 0x02, 0x0F },
    { 0x104c, 0x9F, 0xC8 },
    { 0x1050, 0x80, 0x10 },
    { 0x1052, 0x80, 0x11 },
    { 0x1054, 0x80, 0x12 },
    { 0x1056, 0x80, 0x14 },
    { 0x1058, 0x80, 0x24 },
    { 0x105a, 0x80, 0x27 },
    { 0x105c, 0x80, 0x29 },
    { 0x105e, 0x81, 0x00 },
    { 0x1060, 0x81, 0x10 },
    { 0x1062, 0x81, 0xF0 },
    { 0x1102, 0x00, 0x02 },
    { 0x1104, 0x61, 0xA8 },
    { 0x1136, 0x01, 0x41 },
    { 0x113a, 0x02, 0x0F },
};
#define GVM2TV_TRC_PARAM_COUNT (sizeof(kGVM2TVDefaultTRCParams) / sizeof(kGVM2TVDefaultTRCParams[0]))

#endif /* GVM2TV_SHARED_H */
