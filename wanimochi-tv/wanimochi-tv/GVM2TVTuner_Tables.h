/*
 * GVM2TVTuner_Tables.h - MJ111 Demodulator/Tuner I2C Register Tables
 *
 * Ported from mj111_tables.h (extracted from IODataUSBGVM2TV.kext)
 * Uses GVM2TVUSBTransport::TunerI2CWriteData format.
 */

#ifndef GVM2TVTuner_Tables_h
#define GVM2TVTuner_Tables_h

#include "GVM2TVUSBTransport.h"

using TunerEntry = GVM2TVUSBTransport::TunerI2CWriteData;

/* ---- Initialization Sequence ---- */

/* Tuner Software Reset: write 0xFE 0xC0 0xFF (reset via passthrough) */
static const TunerEntry kTblTunerSwResetTerr[] = {
    { .count = 3, .data = { 0xFE, 0xC0, 0xFF } },
    { .count = 0 },
};

/* Demodulator Init (26 register writes to I2C addr 0x30) */
static const TunerEntry kTblDemodInitTerr[] = {
    { .count = 2, .data = { 0x03, 0x80 } },
    { .count = 2, .data = { 0x09, 0x10 } },
    { .count = 2, .data = { 0x11, 0x26 } },
    { .count = 2, .data = { 0x12, 0x0C } },
    { .count = 2, .data = { 0x13, 0x2B } },
    { .count = 2, .data = { 0x14, 0x40 } },
    { .count = 2, .data = { 0x16, 0x00 } },
    { .count = 2, .data = { 0x1C, 0x2A } },
    { .count = 2, .data = { 0x1D, 0xA0 } },
    { .count = 2, .data = { 0x1E, 0xA8 } },
    { .count = 2, .data = { 0x1F, 0xA8 } },
    { .count = 2, .data = { 0x30, 0x00 } },
    { .count = 2, .data = { 0x31, 0x0D } },
    { .count = 2, .data = { 0x32, 0x79 } },
    { .count = 2, .data = { 0x34, 0x0F } },
    { .count = 2, .data = { 0x38, 0x00 } },
    { .count = 2, .data = { 0x39, 0x94 } },
    { .count = 2, .data = { 0x3A, 0x20 } },
    { .count = 2, .data = { 0x3B, 0x21 } },
    { .count = 2, .data = { 0x3C, 0x3F } },
    { .count = 2, .data = { 0x71, 0x00 } },
    { .count = 2, .data = { 0x75, 0x28 } },
    { .count = 2, .data = { 0x76, 0x0C } },
    { .count = 2, .data = { 0x77, 0x01 } },
    { .count = 2, .data = { 0x7D, 0x80 } },
    { .count = 2, .data = { 0xEF, 0x01 } },
    { .count = 0 },
};

/* Tuner Init: bulk register init via 0xFE passthrough + tuner enable */
static const TunerEntry kTblTunerInitTerr[] = {
    { .count = 36, .data = {
        0xFE, 0xC0, 0x00, 0x3F, 0x02, 0x00, 0x03, 0x48,
        0x04, 0x00, 0x05, 0x04, 0x06, 0x10, 0x2E, 0x15,
        0x30, 0x10, 0x45, 0x58, 0x48, 0x19, 0x52, 0x03,
        0x53, 0x44, 0x6A, 0x4B, 0x76, 0x00, 0x78, 0x18,
        0x7A, 0x17, 0x85, 0x06
    }},
    { .count = 4, .data = { 0xFE, 0xC0, 0x01, 0x01 } },
    { .count = 0 },
};

/* ---- Tuning Sequence Tables ---- */

/* Demodulator Wakeup */
static const TunerEntry kTblDemodWakeupTera[] = {
    { .count = 2, .data = { 0x03, 0x80 } },
    { .count = 2, .data = { 0x1C, 0x2A } },
    { .count = 0 },
};

/* Tuner Wakeup */
static const TunerEntry kTblTunerWakeupTera[] = {
    { .count = 4, .data = { 0xFE, 0xC0, 0x01, 0x01 } },
    { .count = 0 },
};

/* AGC Stop */
static const TunerEntry kTblAGCStopTera[] = {
    { .count = 2, .data = { 0x25, 0x00 } },
    { .count = 2, .data = { 0x23, 0x4D } },
    { .count = 0 },
};

/* Sequencer Stop */
static const TunerEntry kTblSequencerStopTera[] = {
    { .count = 4, .data = { 0xFE, 0xC0, 0x0F, 0x00 } },
    { .count = 0 },
};

/* Bandwidth Setting (ISDB-T = 6 MHz) */
static const TunerEntry kTblBandwidthSettingTera[] = {
    { .count = 4, .data = { 0xFE, 0xC0, 0x0C, 0x15 } },
    { .count = 0 },
};

/* Default Setting 1 */
static const TunerEntry kTblDefaultSetting1Tera[] = {
    { .count = 10, .data = { 0xFE, 0xC0, 0x1F, 0x87, 0x20, 0x1F, 0x21, 0x87, 0x22, 0x1F } },
    { .count = 0 },
};

/* Sequencer Start */
static const TunerEntry kTblSequencerStartTera[] = {
    { .count = 4, .data = { 0xFE, 0xC0, 0x0F, 0x01 } },
    { .count = 0 },
};

/* Sync Sequencer Start */
static const TunerEntry kTblSyncSequencerStartTera[] = {
    { .count = 2, .data = { 0x01, 0x40 } },
    { .count = 0 },
};

/* AGC Start */
static const TunerEntry kTblAGCStartTera[] = {
    { .count = 2, .data = { 0x23, 0x4C } },
    { .count = 0 },
};

/* ---- TS Stream Control ---- */

/* TS Enable */
static const TunerEntry kTblTsEnableTera[] = {
    { .count = 2, .data = { 0x1E, 0x80 } },
    { .count = 2, .data = { 0x1F, 0x08 } },
    { .count = 0 },
};

/* TS Disable */
static const TunerEntry kTblTsDisableTera[] = {
    { .count = 2, .data = { 0x1E, 0xA8 } },
    { .count = 2, .data = { 0x1F, 0xA8 } },
    { .count = 0 },
};

/* ---- Sleep / Power Down ---- */

/* Demodulator Sleep */
static const TunerEntry kTblDemodSleepTera[] = {
    { .count = 2, .data = { 0x1E, 0xA8 } },
    { .count = 2, .data = { 0x1F, 0xA8 } },
    { .count = 2, .data = { 0x1C, 0xAA } },
    { .count = 2, .data = { 0x03, 0xF0 } },
    { .count = 0 },
};

/* Tuner Sleep */
static const TunerEntry kTblTunerSleepTera[] = {
    { .count = 6, .data = { 0xFE, 0xC0, 0x0F, 0x00, 0x01, 0x00 } },
    { .count = 0 },
};

/* ---- Frequency Calculation ---- */

/*
 * ISDB-T UHF channel frequency in kHz.
 * Channel N (13-62): center_freq = N * 6000 + 395143 kHz
 */
static inline uint32_t isdbTChannelToFreqKHz(int channel)
{
    return static_cast<uint32_t>(channel * 6000 + 395143);
}

/*
 * PLL divider for MJ111 tuner.
 * divider = (freq_khz * 64 + 500) / 1000
 */
static inline uint16_t mj111FreqToDivider(uint32_t freq_khz)
{
    return static_cast<uint16_t>((freq_khz * 64 + 500) / 1000);
}

/* Signal strength lookup table (from Mac driver binary) */
static const uint32_t kSignalStrengthTable[100] = {
    22,23,24,25,26,27,28,29,31,32,33,35,36,38,40,42,44,46,48,50,
    53,56,59,62,65,69,72,77,81,86,91,97,103,109,116,124,132,142,
    152,163,175,188,203,219,237,257,280,305,333,364,400,440,486,
    539,599,668,748,840,949,1076,1226,1404,1616,1871,2179,2553,
    3010,3572,4268,5133,6215,7574,9288,11456,14205,17697,22134,
    27774,34938,44027,55546,70126,88557,111834,141220,178318,
    225192,284517,359803,455723,578602,737185,943867,1216799,
    1583680,2089200,2811329,3903296,5735416,9778432
};

#endif /* GVM2TVTuner_Tables_h */
