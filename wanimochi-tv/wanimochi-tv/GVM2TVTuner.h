/*
 * GVM2TVTuner.h - MJ111 Tuner/Demodulator control for GV-M2TV
 *
 * Controls the MJ111 ISDB-T tuner via I2C proxy commands through
 * GVM2TVUSBTransport. Handles initialization, tuning, lock detection,
 * signal strength measurement, and sleep.
 */

#ifndef GVM2TVTuner_h
#define GVM2TVTuner_h

#include <stdint.h>
#include <DriverKit/IOTypes.h>

class GVM2TVUSBTransport;

class GVM2TVTuner {
public:
    explicit GVM2TVTuner(GVM2TVUSBTransport *transport);
    ~GVM2TVTuner();

    /*
     * Initialize MJ111: Software reset, demod init, tuner init.
     * Must be called before any tuning operations.
     * I2C only works when device is in Idle state (0x0011).
     */
    kern_return_t initTuner();

    /*
     * Tune to ISDB-T UHF channel (13-62).
     * Full 14-step tuning sequence from kext StartTuningTera_MJ111.
     * Sets *locked = true if signal lock achieved within 2 seconds.
     */
    kern_return_t tune(int channel, bool *locked);

    /*
     * Check signal lock state.
     * Returns: 0=locked, 1=partial, 2=not locked
     */
    int checkLock();

    /*
     * Get signal strength (0-100).
     * Reads demod registers 0x8B-0x8D and converts via lookup table.
     */
    int getSignalStrength();

    /*
     * Put tuner and demod to sleep: TS disable, tuner sleep, demod sleep.
     */
    kern_return_t sleep();

private:
    GVM2TVUSBTransport *transport_;
};

#endif /* GVM2TVTuner_h */
