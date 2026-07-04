// OutputsSync Nightly — driver virtuel AudioServerPlugIn (loopback).
//
// Périphérique d'ENTRÉE + SORTIE : les apps y jouent (sortie) et le mix est
// rebouclé en interne vers le flux d'ENTRÉE, que l'app OutputsSync lit via un
// agrégat CoreAudio normal. Aucune mémoire partagée (le loopback est interne au
// driver). Comme l'app lit une entrée audio, macOS affiche la pastille micro.
//
// Un contrôle de volume maître (sortie) est exposé : les touches F11/F12 et le
// curseur système agissent dessus, et son gain est appliqué au son rebouclé —
// donc les touches système contrôlent réellement ce que l'app redistribue.
//
// Structure dérivée de l'exemple public « NullAudio » d'Apple + du modèle de
// loopback de BlackHole.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <math.h>
#include <stdatomic.h>
#include <os/log.h>

// MARK: - Identité du device

#define kDevice_Name          "OutputsSync Nightly"
#define kDevice_UID           "OutputsSyncNightlyDevice_UID"
#define kDevice_ModelUID      "OutputsSyncNightlyModel_UID"
#define kBox_UID              "OutputsSyncNightlyBox_UID"
#define kManufacturer         "OutputsSync"

enum {
    kObjectID_PlugIn               = kAudioObjectPlugInObject,  // 1
    kObjectID_Box                  = 2,
    kObjectID_Device               = 3,
    kObjectID_Stream_Input         = 4,
    kObjectID_Stream_Output        = 5,
    kObjectID_Volume_Output_Master = 6
};

#define kChannels        2u
#define kRing_Frames     65536u          // puissance de 2
#define kRing_Mask       (kRing_Frames - 1u)

// Plage du volume maître (touches F11/F12, curseur système, Réglages → Son).
#define kVolume_MinDB (-96.0f)
#define kVolume_MaxDB (0.0f)

// MARK: - État global

static pthread_mutex_t gStateMutex   = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t gIOMutex      = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32  gRefCount = 1;

static Float64 gSampleRate           = 48000.0;
static UInt64  gIORunCount           = 0;
static UInt64  gNumberTimeStamps     = 0;
static UInt64  gAnchorHostTime       = 0;
static Float64 gHostTicksPerFrame    = 1.0;
static bool    gBoxAcquired          = true;
static bool    gInputStreamActive    = true;
static bool    gOutputStreamActive   = true;

// Volume maître, scalaire 0..1. Lu sans verrou par le thread IO temps réel.
static _Atomic Float32 gVolume_Master_Scalar = 1.0f;

// Tampon de loopback interne (sortie -> entrée). Écrit par WriteMix, lu par
// ReadInput, indexé par le temps d'échantillon fourni par coreaudiod.
static Float32 gRingBuffer[kRing_Frames * kChannels];

static os_log_t gLog;

// MARK: - Conversions volume (scalaire ⇄ décibels), mutuellement inverses

static inline Float32 OSN_ScalarToDB(Float32 s)
{
    if (s <= 0.0f) { return kVolume_MinDB; }
    if (s > 1.0f)  { s = 1.0f; }
    Float32 db = 20.0f * log10f(s);
    if (db < kVolume_MinDB) { db = kVolume_MinDB; }
    if (db > kVolume_MaxDB) { db = kVolume_MaxDB; }
    return db;
}

static inline Float32 OSN_DBToScalar(Float32 db)
{
    if (db < kVolume_MinDB) { db = kVolume_MinDB; }
    if (db > kVolume_MaxDB) { db = kVolume_MaxDB; }
    Float32 s = powf(10.0f, db / 20.0f);
    if (s < 0.0f) { s = 0.0f; }
    if (s > 1.0f) { s = 1.0f; }
    return s;
}

// MARK: - Prototypes de l'interface

static HRESULT    OSD_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG      OSD_AddRef(void* inDriver);
static ULONG      OSD_Release(void* inDriver);
static OSStatus   OSD_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus   OSD_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus   OSD_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus   OSD_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus   OSD_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus   OSD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus   OSD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean    OSD_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus   OSD_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus   OSD_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus   OSD_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus   OSD_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus   OSD_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus   OSD_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus   OSD_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus   OSD_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus   OSD_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus   OSD_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus   OSD_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    OSD_QueryInterface,
    OSD_AddRef,
    OSD_Release,
    OSD_Initialize,
    OSD_CreateDevice,
    OSD_DestroyDevice,
    OSD_AddDeviceClient,
    OSD_RemoveDeviceClient,
    OSD_PerformDeviceConfigurationChange,
    OSD_AbortDeviceConfigurationChange,
    OSD_HasProperty,
    OSD_IsPropertySettable,
    OSD_GetPropertyDataSize,
    OSD_GetPropertyData,
    OSD_SetPropertyData,
    OSD_StartIO,
    OSD_StopIO,
    OSD_GetZeroTimeStamp,
    OSD_WillDoIOOperation,
    OSD_BeginIOOperation,
    OSD_DoIOOperation,
    OSD_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory (référencée par Info.plist)

void* OutputsSyncDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* OutputsSyncDriver_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID)
{
    (void)inAllocator;
    gLog = os_log_create("com.outputssync.nightly.driver", "driver");
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

// MARK: - COM

static HRESULT OSD_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface)
{
    if (inDriver != gDriverRef || outInterface == NULL) { return E_POINTER; }
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    if (req) { CFRelease(req); }
    return result;
}

static ULONG OSD_AddRef(void* inDriver)
{
    if (inDriver != gDriverRef) { return 0; }
    pthread_mutex_lock(&gStateMutex);
    ULONG c = (gRefCount < UINT32_MAX) ? ++gRefCount : gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return c;
}

static ULONG OSD_Release(void* inDriver)
{
    if (inDriver != gDriverRef) { return 0; }
    pthread_mutex_lock(&gStateMutex);
    ULONG c = (gRefCount > 0) ? --gRefCount : 0;
    pthread_mutex_unlock(&gStateMutex);
    return c;
}

static OSStatus OSD_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)
{
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    gHost = inHost;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = hostTicksPerSecond / gSampleRate;
    memset(gRingBuffer, 0, sizeof(gRingBuffer));
    os_log(gLog, "Driver loopback initialisé (SR=%.0f).", gSampleRate);
    return noErr;
}

static OSStatus OSD_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* o)
{ (void)d;(void)desc;(void)c;(void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus OSD_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o)
{ (void)d;(void)o; return kAudioHardwareUnsupportedOperationError; }
static OSStatus OSD_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c)
{ (void)d;(void)o;(void)c; return noErr; }
static OSStatus OSD_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo* c)
{ (void)d;(void)o;(void)c; return noErr; }
static OSStatus OSD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i)
{ (void)d;(void)o;(void)a;(void)i; return noErr; }
static OSStatus OSD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 a, void* i)
{ (void)d;(void)o;(void)a;(void)i; return noErr; }

// MARK: - Helpers de format

static void FillASBD(AudioStreamBasicDescription* f)
{
    f->mSampleRate = gSampleRate;
    f->mFormatID = kAudioFormatLinearPCM;
    f->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f->mBytesPerPacket = 8;
    f->mFramesPerPacket = 1;
    f->mBytesPerFrame = 8;
    f->mChannelsPerFrame = 2;
    f->mBitsPerChannel = 32;
    f->mReserved = 0;
}

// MARK: - Filtrage des objets possédés par classe (qualifier du HAL)

static bool OSN_QualifierAccepts(UInt32 qSize, const void* qData, const AudioClassID* accepted, UInt32 nAccepted)
{
    if (qData == NULL || qSize < sizeof(AudioClassID)) { return true; }
    const AudioClassID* req = (const AudioClassID*)qData;
    UInt32 nReq = qSize / sizeof(AudioClassID);
    for (UInt32 i = 0; i < nReq; ++i) {
        for (UInt32 j = 0; j < nAccepted; ++j) {
            if (req[i] == accepted[j]) { return true; }
        }
    }
    return false;
}

static const AudioClassID kOSN_StreamClasses[] = { kAudioStreamClassID, kAudioObjectClassID };
static const AudioClassID kOSN_VolumeClasses[] = { kAudioVolumeControlClassID, kAudioLevelControlClassID, kAudioControlClassID, kAudioObjectClassID };

// MARK: - HasProperty (délègue à GetPropertyDataSize)

static Boolean OSD_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress)
{
    UInt32 size = 0;
    return OSD_GetPropertyDataSize(inDriver, inObjectID, inClientPID, inAddress, 0, NULL, &size) == noErr;
}

static OSStatus OSD_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable)
{
    (void)inDriver;(void)inClientPID;
    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        *outIsSettable = true;
    } else if (inObjectID == kObjectID_Box &&
               (inAddress->mSelector == kAudioObjectPropertyName ||
                inAddress->mSelector == kAudioBoxPropertyAcquired)) {
        *outIsSettable = true;
    } else if (inObjectID == kObjectID_Volume_Output_Master &&
               (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
                inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        *outIsSettable = true;
    } else {
        *outIsSettable = false;
    }
    return noErr;
}

// MARK: - GetPropertyDataSize

static OSStatus OSD_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32* outSize)
{
    (void)inDriver;(void)inClientPID;
    if (outSize == NULL) { return kAudioHardwareIllegalOperationError; }

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:      *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:          *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:          *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyManufacturer:   *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:   *outSize = 2 * sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyBoxList:        *outSize = 1 * sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyTranslateUIDToBox: *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyDeviceList:     *outSize = 1 * sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyTranslateUIDToDevice: *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioPlugInPropertyResourceBundle: *outSize = sizeof(CFStringRef); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Box:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:      *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:          *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:          *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:           *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer:   *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects:   *outSize = 0; return noErr;
                case kAudioObjectPropertyIdentify:       *outSize = sizeof(UInt32); return noErr;
                case kAudioObjectPropertyModelName:      *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertySerialNumber:   *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyFirmwareVersion:*outSize = sizeof(CFStringRef); return noErr;
                case kAudioBoxPropertyBoxUID:            *outSize = sizeof(CFStringRef); return noErr;
                case kAudioBoxPropertyTransportType:     *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyHasAudio:          *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyHasVideo:          *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyHasMIDI:           *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyIsProtected:       *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyAcquired:          *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyAcquisitionFailed: *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyDeviceList:        *outSize = (gBoxAcquired ? 1 : 0) * sizeof(AudioObjectID); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:      *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:          *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:          *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:           *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer:   *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects: {
                    UInt32 count = 0;
                    if (OSN_QualifierAccepts(q, qd, kOSN_StreamClasses, 2)) { count += 2; }  // input + output
                    if (OSN_QualifierAccepts(q, qd, kOSN_VolumeClasses, 4)) { count += 1; }
                    *outSize = count * sizeof(AudioObjectID); return noErr;
                }
                case kAudioDevicePropertyDeviceUID:      *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyModelUID:       *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyTransportType:  *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyRelatedDevices: *outSize = 1 * sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertyClockDomain:    *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsAlive:  *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsRunning:*outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultDevice:       *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyLatency:        *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyStreams: {
                    UInt32 n = 0;
                    if (a->mScope == kAudioObjectPropertyScopeGlobal) { n = 2; }
                    else if (a->mScope == kAudioObjectPropertyScopeInput) { n = 1; }
                    else if (a->mScope == kAudioObjectPropertyScopeOutput) { n = 1; }
                    *outSize = n * sizeof(AudioObjectID); return noErr;
                }
                case kAudioObjectPropertyControlList:    *outSize = 1 * sizeof(AudioObjectID); return noErr;
                case kAudioDevicePropertySafetyOffset:   *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyNominalSampleRate: *outSize = sizeof(Float64); return noErr;
                case kAudioDevicePropertyAvailableNominalSampleRates: *outSize = 2 * sizeof(AudioValueRange); return noErr;
                case kAudioDevicePropertyIsHidden:       *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyZeroTimeStampPeriod: *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelsForStereo: *outSize = 2 * sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelLayout: *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription)); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:      *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:          *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:          *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyOwnedObjects:   *outSize = 0; return noErr;
                case kAudioStreamPropertyIsActive:       *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyDirection:      *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyTerminalType:   *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyStartingChannel:*outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyLatency:        *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: *outSize = sizeof(AudioStreamBasicDescription); return noErr;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: *outSize = sizeof(AudioStreamRangedDescription); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Volume_Output_Master:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass:      *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:          *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:          *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyOwnedObjects:   *outSize = 0; return noErr;
                case kAudioControlPropertyScope:         *outSize = sizeof(AudioObjectPropertyScope); return noErr;
                case kAudioControlPropertyElement:       *outSize = sizeof(AudioObjectPropertyElement); return noErr;
                case kAudioLevelControlPropertyScalarValue: *outSize = sizeof(Float32); return noErr;
                case kAudioLevelControlPropertyDecibelValue: *outSize = sizeof(Float32); return noErr;
                case kAudioLevelControlPropertyDecibelRange: *outSize = sizeof(AudioValueRange); return noErr;
                case kAudioLevelControlPropertyConvertScalarToDecibels: *outSize = sizeof(Float32); return noErr;
                case kAudioLevelControlPropertyConvertDecibelsToScalar: *outSize = sizeof(Float32); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }
    }
    return kAudioHardwareBadObjectError;
}

// MARK: - GetPropertyData

static OSStatus OSD_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 inDataSize, UInt32* outSize, void* outData)
{
    (void)inDriver;(void)inClientPID;

    switch (inObjectID) {
        case kObjectID_PlugIn:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData) = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:     *((AudioClassID*)outData) = kAudioPlugInClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:     *((AudioObjectID*)outData) = kAudioObjectUnknown; *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyManufacturer: *((CFStringRef*)outData) = CFSTR(kManufacturer); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 want = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    if (n < want) { list[n++] = kObjectID_Box; }
                    if (n < want) { list[n++] = kObjectID_Device; }
                    *outSize = n * sizeof(AudioObjectID); return noErr;
                }
                case kAudioPlugInPropertyBoxList: {
                    if (inDataSize >= sizeof(AudioObjectID)) { ((AudioObjectID*)outData)[0] = kObjectID_Box; *outSize = sizeof(AudioObjectID); }
                    else { *outSize = 0; }
                    return noErr;
                }
                case kAudioPlugInPropertyTranslateUIDToBox: {
                    CFStringRef uid = *((CFStringRef*)qd);
                    *((AudioObjectID*)outData) = CFEqual(uid, CFSTR(kBox_UID)) ? kObjectID_Box : kAudioObjectUnknown;
                    *outSize = sizeof(AudioObjectID); return noErr;
                }
                case kAudioPlugInPropertyDeviceList: {
                    if (gBoxAcquired && inDataSize >= sizeof(AudioObjectID)) { ((AudioObjectID*)outData)[0] = kObjectID_Device; *outSize = sizeof(AudioObjectID); }
                    else { *outSize = 0; }
                    return noErr;
                }
                case kAudioPlugInPropertyTranslateUIDToDevice: {
                    CFStringRef uid = *((CFStringRef*)qd);
                    *((AudioObjectID*)outData) = CFEqual(uid, CFSTR(kDevice_UID)) ? kObjectID_Device : kAudioObjectUnknown;
                    *outSize = sizeof(AudioObjectID); return noErr;
                }
                case kAudioPlugInPropertyResourceBundle: *((CFStringRef*)outData) = CFSTR(""); *outSize = sizeof(CFStringRef); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Box:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData) = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:     *((AudioClassID*)outData) = kAudioBoxClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:     *((AudioObjectID*)outData) = kObjectID_PlugIn; *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:      *((CFStringRef*)outData) = CFSTR(kDevice_Name " Box"); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyModelName: *((CFStringRef*)outData) = CFSTR(kDevice_Name); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer: *((CFStringRef*)outData) = CFSTR(kManufacturer); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
                case kAudioObjectPropertyIdentify:  *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioObjectPropertySerialNumber: *((CFStringRef*)outData) = CFSTR("1"); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyFirmwareVersion: *((CFStringRef*)outData) = CFSTR("1.0"); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioBoxPropertyBoxUID:       *((CFStringRef*)outData) = CFSTR(kBox_UID); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioBoxPropertyTransportType:*((UInt32*)outData) = kAudioDeviceTransportTypeVirtual; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyHasAudio:     *((UInt32*)outData) = 1; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyHasVideo:     *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyHasMIDI:      *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyIsProtected:  *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyAcquired:     *((UInt32*)outData) = gBoxAcquired ? 1 : 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyAcquisitionFailed: *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioBoxPropertyDeviceList: {
                    if (gBoxAcquired && inDataSize >= sizeof(AudioObjectID)) { ((AudioObjectID*)outData)[0] = kObjectID_Device; *outSize = sizeof(AudioObjectID); }
                    else { *outSize = 0; }
                    return noErr;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Device:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData) = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:     *((AudioClassID*)outData) = kAudioDeviceClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:     *((AudioObjectID*)outData) = kObjectID_PlugIn; *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyName:      *((CFStringRef*)outData) = CFSTR(kDevice_Name); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyManufacturer: *((CFStringRef*)outData) = CFSTR(kManufacturer); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioObjectPropertyOwnedObjects: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 want = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    if (OSN_QualifierAccepts(q, qd, kOSN_StreamClasses, 2) && n < want) { list[n++] = kObjectID_Stream_Input; }
                    if (OSN_QualifierAccepts(q, qd, kOSN_StreamClasses, 2) && n < want) { list[n++] = kObjectID_Stream_Output; }
                    if (OSN_QualifierAccepts(q, qd, kOSN_VolumeClasses, 4) && n < want) { list[n++] = kObjectID_Volume_Output_Master; }
                    *outSize = n * sizeof(AudioObjectID); return noErr;
                }
                case kAudioDevicePropertyDeviceUID: *((CFStringRef*)outData) = CFSTR(kDevice_UID); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyModelUID:  *((CFStringRef*)outData) = CFSTR(kDevice_ModelUID); *outSize = sizeof(CFStringRef); return noErr;
                case kAudioDevicePropertyTransportType: *((UInt32*)outData) = kAudioDeviceTransportTypeVirtual; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyRelatedDevices: {
                    if (inDataSize >= sizeof(AudioObjectID)) { ((AudioObjectID*)outData)[0] = kObjectID_Device; *outSize = sizeof(AudioObjectID); }
                    else { *outSize = 0; }
                    return noErr;
                }
                case kAudioDevicePropertyClockDomain: *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsAlive: *((UInt32*)outData) = 1; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceIsRunning: {
                    pthread_mutex_lock(&gStateMutex);
                    *((UInt32*)outData) = (gIORunCount > 0) ? 1 : 0;
                    pthread_mutex_unlock(&gStateMutex);
                    *outSize = sizeof(UInt32); return noErr;
                }
                case kAudioDevicePropertyDeviceCanBeDefaultDevice: *((UInt32*)outData) = 1; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *((UInt32*)outData) = 1; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyLatency: *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyStreams: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 want = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    if ((a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeInput) && n < want) {
                        list[n++] = kObjectID_Stream_Input;
                    }
                    if ((a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput) && n < want) {
                        list[n++] = kObjectID_Stream_Output;
                    }
                    *outSize = n * sizeof(AudioObjectID); return noErr;
                }
                case kAudioObjectPropertyControlList: {
                    AudioObjectID* list = (AudioObjectID*)outData;
                    UInt32 want = inDataSize / sizeof(AudioObjectID);
                    UInt32 n = 0;
                    if (n < want) { list[n++] = kObjectID_Volume_Output_Master; }
                    *outSize = n * sizeof(AudioObjectID); return noErr;
                }
                case kAudioDevicePropertySafetyOffset: *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyNominalSampleRate: {
                    pthread_mutex_lock(&gStateMutex);
                    *((Float64*)outData) = gSampleRate;
                    pthread_mutex_unlock(&gStateMutex);
                    *outSize = sizeof(Float64); return noErr;
                }
                case kAudioDevicePropertyAvailableNominalSampleRates: {
                    AudioValueRange* r = (AudioValueRange*)outData;
                    UInt32 want = inDataSize / sizeof(AudioValueRange);
                    UInt32 n = 0;
                    if (n < want) { r[n].mMinimum = 44100; r[n].mMaximum = 44100; n++; }
                    if (n < want) { r[n].mMinimum = 48000; r[n].mMaximum = 48000; n++; }
                    *outSize = n * sizeof(AudioValueRange); return noErr;
                }
                case kAudioDevicePropertyIsHidden: *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyZeroTimeStampPeriod: *((UInt32*)outData) = kRing_Frames; *outSize = sizeof(UInt32); return noErr;
                case kAudioDevicePropertyPreferredChannelsForStereo: {
                    UInt32* ch = (UInt32*)outData; ch[0] = 1; ch[1] = 2; *outSize = 2 * sizeof(UInt32); return noErr;
                }
                case kAudioDevicePropertyPreferredChannelLayout: {
                    AudioChannelLayout* l = (AudioChannelLayout*)outData;
                    l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                    l->mChannelBitmap = 0;
                    l->mNumberChannelDescriptions = 2;
                    l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                    l->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                    for (int i = 0; i < 2; i++) { l->mChannelDescriptions[i].mChannelFlags = 0; l->mChannelDescriptions[i].mCoordinates[0]=0; l->mChannelDescriptions[i].mCoordinates[1]=0; l->mChannelDescriptions[i].mCoordinates[2]=0; }
                    *outSize = offsetof(AudioChannelLayout, mChannelDescriptions) + 2 * sizeof(AudioChannelDescription);
                    return noErr;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }

        case kObjectID_Stream_Input:
        case kObjectID_Stream_Output: {
            bool isInput = (inObjectID == kObjectID_Stream_Input);
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData) = kAudioObjectClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:     *((AudioClassID*)outData) = kAudioStreamClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:     *((AudioObjectID*)outData) = kObjectID_Device; *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
                case kAudioStreamPropertyIsActive:  *((UInt32*)outData) = (isInput ? gInputStreamActive : gOutputStreamActive) ? 1 : 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyDirection: *((UInt32*)outData) = isInput ? 1 : 0; *outSize = sizeof(UInt32); return noErr; // 1 = entrée, 0 = sortie
                case kAudioStreamPropertyTerminalType: *((UInt32*)outData) = isInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker; *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyStartingChannel: *((UInt32*)outData) = 1; *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyLatency:   *((UInt32*)outData) = 0; *outSize = sizeof(UInt32); return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat: {
                    pthread_mutex_lock(&gStateMutex);
                    FillASBD((AudioStreamBasicDescription*)outData);
                    pthread_mutex_unlock(&gStateMutex);
                    *outSize = sizeof(AudioStreamBasicDescription); return noErr;
                }
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats: {
                    AudioStreamRangedDescription* d = (AudioStreamRangedDescription*)outData;
                    FillASBD(&d->mFormat);
                    d->mSampleRateRange.mMinimum = 44100;
                    d->mSampleRateRange.mMaximum = 48000;
                    *outSize = sizeof(AudioStreamRangedDescription); return noErr;
                }
                default: return kAudioHardwareUnknownPropertyError;
            }
        }

        case kObjectID_Volume_Output_Master:
            switch (a->mSelector) {
                case kAudioObjectPropertyBaseClass: *((AudioClassID*)outData) = kAudioLevelControlClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyClass:     *((AudioClassID*)outData) = kAudioVolumeControlClassID; *outSize = sizeof(AudioClassID); return noErr;
                case kAudioObjectPropertyOwner:     *((AudioObjectID*)outData) = kObjectID_Device; *outSize = sizeof(AudioObjectID); return noErr;
                case kAudioObjectPropertyOwnedObjects: *outSize = 0; return noErr;
                case kAudioControlPropertyScope:    *((AudioObjectPropertyScope*)outData) = kAudioObjectPropertyScopeOutput; *outSize = sizeof(AudioObjectPropertyScope); return noErr;
                case kAudioControlPropertyElement:  *((AudioObjectPropertyElement*)outData) = kAudioObjectPropertyElementMain; *outSize = sizeof(AudioObjectPropertyElement); return noErr;
                case kAudioLevelControlPropertyScalarValue:
                    *((Float32*)outData) = atomic_load_explicit(&gVolume_Master_Scalar, memory_order_relaxed);
                    *outSize = sizeof(Float32); return noErr;
                case kAudioLevelControlPropertyDecibelValue:
                    *((Float32*)outData) = OSN_ScalarToDB(atomic_load_explicit(&gVolume_Master_Scalar, memory_order_relaxed));
                    *outSize = sizeof(Float32); return noErr;
                case kAudioLevelControlPropertyDecibelRange: {
                    AudioValueRange* r = (AudioValueRange*)outData;
                    r->mMinimum = kVolume_MinDB;
                    r->mMaximum = kVolume_MaxDB;
                    *outSize = sizeof(AudioValueRange); return noErr;
                }
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                    *((Float32*)outData) = OSN_ScalarToDB(*((Float32*)outData));
                    *outSize = sizeof(Float32); return noErr;
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    *((Float32*)outData) = OSN_DBToScalar(*((Float32*)outData));
                    *outSize = sizeof(Float32); return noErr;
                default: return kAudioHardwareUnknownPropertyError;
            }
    }
    return kAudioHardwareBadObjectError;
}

// MARK: - SetPropertyData

static OSStatus OSD_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 q, const void* qd, UInt32 inDataSize, const void* inData)
{
    (void)inDriver;(void)inClientPID;(void)q;(void)qd;(void)inDataSize;

    if (inObjectID == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        Float64 newRate = *((const Float64*)inData);
        if (newRate != 44100.0 && newRate != 48000.0) { return kAudioHardwareIllegalOperationError; }
        pthread_mutex_lock(&gStateMutex);
        Float64 old = gSampleRate;
        gSampleRate = newRate;
        struct mach_timebase_info tb; mach_timebase_info(&tb);
        Float64 hostTicksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
        gHostTicksPerFrame = hostTicksPerSecond / gSampleRate;
        pthread_mutex_unlock(&gStateMutex);
        if (old != newRate && gHost != NULL) {
            gHost->RequestDeviceConfigurationChange(gHost, kObjectID_Device, 0, NULL);
        }
        return noErr;
    }
    if (inObjectID == kObjectID_Box && a->mSelector == kAudioBoxPropertyAcquired) {
        return noErr;
    }
    if (inObjectID == kObjectID_Volume_Output_Master &&
        (a->mSelector == kAudioLevelControlPropertyScalarValue ||
         a->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        Float32 newScalar;
        if (a->mSelector == kAudioLevelControlPropertyScalarValue) {
            newScalar = *((const Float32*)inData);
        } else {
            newScalar = OSN_DBToScalar(*((const Float32*)inData));
        }
        if (newScalar < 0.0f) { newScalar = 0.0f; }
        if (newScalar > 1.0f) { newScalar = 1.0f; }
        atomic_store_explicit(&gVolume_Master_Scalar, newScalar, memory_order_relaxed);
        if (gHost != NULL) {
            AudioObjectPropertyAddress changed[2] = {
                { kAudioLevelControlPropertyScalarValue,  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
                { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }
            };
            gHost->PropertiesChanged(gHost, kObjectID_Volume_Output_Master, 2, changed);
        }
        return noErr;
    }
    return kAudioHardwareUnknownPropertyError;
}

// MARK: - IO

static OSStatus OSD_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    if (inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    pthread_mutex_lock(&gStateMutex);
    if (gIORunCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        memset(gRingBuffer, 0, sizeof(gRingBuffer));
    }
    gIORunCount++;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus OSD_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)
{
    (void)inClientID;
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    if (inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    pthread_mutex_lock(&gStateMutex);
    if (gIORunCount > 0) { gIORunCount--; }
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus OSD_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed)
{
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    pthread_mutex_lock(&gIOMutex);
    UInt64 currentHostTime = mach_absolute_time();
    Float64 hostTicksPerRing = gHostTicksPerFrame * (Float64)kRing_Frames;
    Float64 offset = ((Float64)(gNumberTimeStamps + 1)) * hostTicksPerRing;
    UInt64 nextHostTime = gAnchorHostTime + (UInt64)offset;
    if (currentHostTime >= nextHostTime) { gNumberTimeStamps++; }
    *outSampleTime = (Float64)(gNumberTimeStamps * kRing_Frames);
    *outHostTime = gAnchorHostTime + (UInt64)(((Float64)gNumberTimeStamps) * hostTicksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gIOMutex);
    return noErr;
}

static OSStatus OSD_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace)
{
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) { return kAudioHardwareBadObjectError; }
    Boolean willDo = false, inPlace = true;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationWriteMix: willDo = true; inPlace = true; break;
        case kAudioServerPlugInIOOperationReadInput: willDo = true; inPlace = false; break;
        default: willDo = false; inPlace = true; break;
    }
    if (outWillDo) { *outWillDo = willDo; }
    if (outWillDoInPlace) { *outWillDoInPlace = inPlace; }
    return noErr;
}

static OSStatus OSD_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;(void)inIOBufferFrameSize;(void)inIOCycleInfo; return noErr; }

static OSStatus OSD_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer)
{
    (void)inDriver;(void)inDeviceObjectID;(void)inStreamObjectID;(void)inClientID;(void)ioSecondaryBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && ioMainBuffer != NULL) {
        // Le mix des apps arrive : on l'écrit dans le ring (avec le gain volume),
        // indexé par le temps d'échantillon de sortie.
        const float* src = (const float*)ioMainBuffer;
        Float32 gain = atomic_load_explicit(&gVolume_Master_Scalar, memory_order_relaxed);
        UInt64 t = (UInt64)inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            UInt32 idx = (UInt32)((t + f) & kRing_Mask) * kChannels;
            gRingBuffer[idx]     = src[f * 2]     * gain;
            gRingBuffer[idx + 1] = src[f * 2 + 1] * gain;
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput && ioMainBuffer != NULL) {
        // L'app lit l'entrée : on lui rend le ring, indexé par le temps
        // d'échantillon d'entrée (décalé → le loopback).
        float* dst = (float*)ioMainBuffer;
        UInt64 t = (UInt64)inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            UInt32 idx = (UInt32)((t + f) & kRing_Mask) * kChannels;
            dst[f * 2]     = gRingBuffer[idx];
            dst[f * 2 + 1] = gRingBuffer[idx + 1];
        }
    }
    return noErr;
}

static OSStatus OSD_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo)
{ (void)inDriver;(void)inDeviceObjectID;(void)inClientID;(void)inOperationID;(void)inIOBufferFrameSize;(void)inIOCycleInfo; return noErr; }
