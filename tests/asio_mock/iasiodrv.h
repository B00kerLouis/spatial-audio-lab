#pragma once
// Test double for the subset of the ASIO interface used by the host. This is
// not an SDK replacement and is not used to validate Windows ABI compatibility.
using ASIOError = long;
using ASIOBool = long;
using ASIOSampleRate = double;
constexpr long ASE_OK = 0, ASE_SUCCESS = 0x3f4847a0, ASE_NotPresent = -1000;
constexpr long ASIOFalse = 0;
enum {
    kAsioSelectorSupported = 1, kAsioEngineVersion, kAsioResetRequest,
    kAsioBufferSizeChange, kAsioResyncRequest, kAsioLatenciesChanged,
    kAsioSupportsTimeInfo
};
struct ASIOTime {};
struct ASIOBufferInfo { ASIOBool isInput{}; long channelNum{}; void* buffers[2]{}; };
struct ASIOChannelInfo { long channel{}; ASIOBool isInput{}; long type{}; char name[32]{}; };
struct ASIOCallbacks {
    void (*bufferSwitch)(long, ASIOBool);
    void (*sampleRateDidChange)(ASIOSampleRate);
    long (*asioMessage)(long, long, void*, double*);
    ASIOTime* (*bufferSwitchTimeInfo)(ASIOTime*, long, ASIOBool);
};
struct IASIO {
    virtual ~IASIO() = default;
    virtual unsigned long Release() = 0;
    virtual ASIOBool init(void*) = 0;
    virtual ASIOError start() = 0;
    virtual ASIOError stop() = 0;
    virtual ASIOError getChannels(long*, long*) = 0;
    virtual ASIOError getLatencies(long*, long*) = 0;
    virtual ASIOError getBufferSize(long*, long*, long*, long*) = 0;
    virtual ASIOError canSampleRate(ASIOSampleRate) = 0;
    virtual ASIOError getSampleRate(ASIOSampleRate*) = 0;
    virtual ASIOError setSampleRate(ASIOSampleRate) = 0;
    virtual ASIOError getChannelInfo(ASIOChannelInfo*) = 0;
    virtual ASIOError createBuffers(ASIOBufferInfo*, long, long, ASIOCallbacks*) = 0;
    virtual ASIOError disposeBuffers() = 0;
    virtual ASIOError outputReady() = 0;
};
