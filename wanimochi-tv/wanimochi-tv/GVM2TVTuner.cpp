/*
 * GVM2TVTuner.cpp - MJ111 Tuner/Demodulator control implementation
 *
 * Ported from gvm2tv-stream.c init_tuner() and tune_channel() functions.
 */

#include <os/log.h>
#include <string.h>
#include <DriverKit/IOLib.h>

#include "GVM2TVTuner.h"
#include "GVM2TVUSBTransport.h"
#include "GVM2TVTuner_Tables.h"
#include "GVM2TVShared.h"

#define LOG_PREFIX "GVM2TVTuner"

GVM2TVTuner::GVM2TVTuner(GVM2TVUSBTransport *transport)
    : transport_(transport)
{
}

GVM2TVTuner::~GVM2TVTuner()
{
}

kern_return_t GVM2TVTuner::initTuner()
{
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": initializing MJ111");
    kern_return_t ret;

    /* Step 1: Tuner software reset */
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": tuner SW reset");
    ret = transport_->i2cWriteTable(kTblTunerSwResetTerr);
    if (ret != kIOReturnSuccess) return ret;
    IOSleep(50); /* 50ms after reset */

    /* Step 2: Demodulator init (26 registers) */
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": demod init");
    ret = transport_->i2cWriteTable(kTblDemodInitTerr);
    if (ret != kIOReturnSuccess) return ret;

    /* Verify I2C communication */
    uint8_t r03 = 0;
    transport_->i2cRead(0x03, &r03, 1);
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": reg 0x03 = 0x%02x (expect 0x80)", r03);
    if (r03 != 0x80) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": WARNING: I2C readback mismatch");
    }

    /* Step 3: Tuner init */
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": tuner init");
    ret = transport_->i2cWriteTable(kTblTunerInitTerr);
    if (ret != kIOReturnSuccess) return ret;

    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": MJ111 initialization complete");
    return kIOReturnSuccess;
}

kern_return_t GVM2TVTuner::tune(int channel, bool *locked)
{
    if (channel < 13 || channel > 62) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": invalid channel %d (must be 13-62)", channel);
        return kIOReturnBadArgument;
    }

    *locked = false;
    uint32_t freq_khz = isdbTChannelToFreqKHz(channel);
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": tuning ch%d -> %u kHz", channel, freq_khz);

    kern_return_t ret;

    /* 1. Demod wakeup */
    ret = transport_->i2cWriteTable(kTblDemodWakeupTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 2. Tuner wakeup */
    ret = transport_->i2cWriteTable(kTblTunerWakeupTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 3. Stop stream (GPIO STOP command) */
    uint8_t stopCmd[6] = { 0x00, 0x00, 0x05, 0x00, 0x00, 0x00 };
    transport_->setApiCmd(stopCmd);
    uint8_t ack[64];
    transport_->getAck(ack, 500);

    /* 4. AGC stop */
    ret = transport_->i2cWriteTable(kTblAGCStopTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 5. Sequencer stop */
    ret = transport_->i2cWriteTable(kTblSequencerStopTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 6. Bandwidth (6MHz for ISDB-T) */
    ret = transport_->i2cWriteTable(kTblBandwidthSettingTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 7. Frequency setting */
    {
        uint16_t divider = mj111FreqToDivider(freq_khz);
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": PLL divider: 0x%04x", divider);

        TunerEntry freqTbl[2] = {};
        freqTbl[0].count = 6;
        freqTbl[0].data[0] = 0xFE;
        freqTbl[0].data[1] = 0xC0;
        freqTbl[0].data[2] = 0x0D;
        freqTbl[0].data[3] = divider & 0xFF;
        freqTbl[0].data[4] = 0x0E;
        freqTbl[0].data[5] = (divider >> 8) & 0xFF;
        freqTbl[1].count = 0;

        ret = transport_->i2cWriteTable(freqTbl);
        if (ret != kIOReturnSuccess) return ret;
    }

    /* 8. Default setting 1 */
    ret = transport_->i2cWriteTable(kTblDefaultSetting1Tera);
    if (ret != kIOReturnSuccess) return ret;

    /* 9. Default setting 2 (frequency-dependent threshold) */
    {
        TunerEntry ds2Tbl[2] = {};
        ds2Tbl[0].count = 4;
        ds2Tbl[0].data[0] = 0xFE;
        ds2Tbl[0].data[1] = 0xC0;
        ds2Tbl[0].data[2] = 0x80;
        ds2Tbl[0].data[3] = (freq_khz < 333000) ? 0x01 : 0x41;
        ds2Tbl[1].count = 0;

        ret = transport_->i2cWriteTable(ds2Tbl);
        if (ret != kIOReturnSuccess) return ret;
    }

    /* 10. Sequencer start */
    ret = transport_->i2cWriteTable(kTblSequencerStartTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 11. Sync sequencer start */
    ret = transport_->i2cWriteTable(kTblSyncSequencerStartTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 12. AGC start */
    ret = transport_->i2cWriteTable(kTblAGCStartTera);
    if (ret != kIOReturnSuccess) return ret;

    /* 13. Wait for lock (up to 2 seconds) */
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": waiting for signal lock...");
    for (int i = 0; i < 20; i++) {
        IOSleep(100); /* 100ms */
        int lockState = checkLock();
        if (lockState == 0) {
            os_log(OS_LOG_DEFAULT, LOG_PREFIX ": LOCKED after %dms", (i + 1) * 100);
            *locked = true;
            break;
        }
    }

    if (!*locked) {
        os_log(OS_LOG_DEFAULT, LOG_PREFIX ": no signal lock after 2000ms");
    }

    /* Read signal strength */
    int strength = getSignalStrength();
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": signal strength = %d/100", strength);

    /* 14. TS enable */
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": enabling TS output");
    ret = transport_->i2cWriteTable(kTblTsEnableTera);
    if (ret != kIOReturnSuccess) return ret;

    return kIOReturnSuccess;
}

int GVM2TVTuner::checkLock()
{
    uint8_t r80 = 0, rb0 = 0, r96 = 0;
    transport_->i2cRead(0x80, &r80, 1);
    transport_->i2cRead(0xB0, &rb0, 1);
    transport_->i2cRead(0x96, &r96, 1);

    /*
     * Lock detection from Mac driver:
     * 1. reg 0x80: if bits 3+5 (0x28) set → error
     * 2. reg 0xB0: lower nibble > 7 → check reg 0x96
     * 3. reg 0x96: if any of bits 5,6,7 set → LOCKED
     */
    if (r80 & 0x28) {
        return (r80 & 0x80) ? 0 : 1;
    }
    if ((rb0 & 0x0F) > 7) {
        if (r96 & 0xE0) return 0; /* LOCKED */
        return 1; /* partial */
    }
    return 2; /* not locked */
}

int GVM2TVTuner::getSignalStrength()
{
    uint8_t s0 = 0, s1 = 0, s2 = 0;
    transport_->i2cRead(0x8B, &s0, 1);
    transport_->i2cRead(0x8C, &s1, 1);
    transport_->i2cRead(0x8D, &s2, 1);
    uint32_t raw = (static_cast<uint32_t>(s0) << 16)
                 | (static_cast<uint32_t>(s1) << 8)
                 | s2;

    if (raw == 0) return 0;

    int level = 100;
    for (int t = 0; t < 100; t++) {
        if (raw < kSignalStrengthTable[t]) {
            level = 100 - t;
            break;
        }
    }
    if (level == 100 && raw >= kSignalStrengthTable[99]) level = 0;
    return level;
}

kern_return_t GVM2TVTuner::sleep()
{
    os_log(OS_LOG_DEFAULT, LOG_PREFIX ": putting tuner to sleep");
    kern_return_t ret;

    /* TS disable */
    ret = transport_->i2cWriteTable(kTblTsDisableTera);
    if (ret != kIOReturnSuccess) return ret;

    /* Tuner sleep */
    ret = transport_->i2cWriteTable(kTblTunerSleepTera);
    if (ret != kIOReturnSuccess) return ret;

    /* Demod sleep */
    ret = transport_->i2cWriteTable(kTblDemodSleepTera);
    if (ret != kIOReturnSuccess) return ret;

    return kIOReturnSuccess;
}
