/*
 * GVM2TVStreamEngine.h - EP1 async bulk streaming + ring buffer
 *
 * Reads TS packets from USB EP1 and writes them to a shared memory
 * ring buffer that the companion app reads from.
 */

#ifndef GVM2TVStreamEngine_h
#define GVM2TVStreamEngine_h

#include <stdint.h>
#include <DriverKit/IOTypes.h>

struct GVM2TVRingBufferHeader;
class GVM2TVUSBTransport;
class IODispatchQueue;

class GVM2TVStreamEngine {
public:
    explicit GVM2TVStreamEngine(GVM2TVUSBTransport *transport);
    ~GVM2TVStreamEngine();

    /*
     * Set the shared memory ring buffer.
     * Called by GVM2TVUserClient after allocating the buffer.
     */
    void setRingBuffer(GVM2TVRingBufferHeader *header, uint8_t *dataArea, uint64_t dataSize);

    /*
     * Start streaming: begins reading TS data from EP1 in a loop.
     * The companion app must have already sent the START command.
     */
    kern_return_t start();

    /*
     * Stop streaming: terminates the EP1 read loop.
     */
    void stop();

    /*
     * Get streaming statistics.
     */
    void getStats(uint64_t *totalBytes, uint64_t *totalPackets);

private:
    GVM2TVUSBTransport   *transport_;
    IODispatchQueue      *readQueue_;
    GVM2TVRingBufferHeader *ringHeader_;
    uint8_t              *ringData_;
    uint64_t              ringSize_;
    volatile bool         running_;
    volatile bool         readerScheduled_;
    volatile bool         readerActive_;
    uint64_t              totalBytes_;
    uint64_t              totalPackets_;

    static void readLoopThunk(void *context);
    void readLoop();

    /* Write data to the ring buffer */
    void writeToRingBuffer(const uint8_t *data, uint32_t len);
};

#endif /* GVM2TVStreamEngine_h */
