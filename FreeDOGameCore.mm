/*
 Copyright (c) 2014, OpenEmu Team
 
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of the OpenEmu Team nor the
 names of its contributors may be used to endorse or promote products
 derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "FreeDOGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OE3DOSystemResponderClient.h"
#import <OpenGL/gl.h>

#include "freedocore.h"
#include "frame.h"
#include "libcue.h"
#include "cd.h"

#define TEMP_BUFFER_SIZE 5512
#define ROM1_SIZE 1 * 1024 * 1024
#define ROM2_SIZE 933636 //was 1 * 1024 * 1024,
#define NVRAM_SIZE 32 * 1024

#define INPUTBUTTONL     (1<<4)
#define INPUTBUTTONR     (1<<5)
#define INPUTBUTTONX     (1<<6)
#define INPUTBUTTONP     (1<<7)
#define INPUTBUTTONC     (1<<8)
#define INPUTBUTTONB     (1<<9)
#define INPUTBUTTONA     (1<<10)
#define INPUTBUTTONLEFT  (1<<11)
#define INPUTBUTTONRIGHT (1<<12)
#define INPUTBUTTONUP    (1<<13)
#define INPUTBUTTONDOWN  (1<<14)

typedef struct{
    int buttons; // buttons bitfield
}inputState;

inputState internal_input_state[6];

@interface FreeDOGameCore () <OE3DOSystemResponderClient>
{
    NSString *romName;
    
    unsigned char *biosRom1Copy;
    unsigned char *biosRom2Copy;
    VDLFrame *frame;
    
    NSFileHandle *isoStream;
    TrackMode isoMode;
    int sectorCount;
    int currentSector;
    BOOL isSwapFrameSignaled;
    
    int fver1,fver2;
    
    uint32_t *videoBuffer;
    int videoWidth, videoHeight;
    //uintptr_t sampleBuffer[TEMP_BUFFER_SIZE];
    int32_t sampleBuffer[TEMP_BUFFER_SIZE];
    uint sampleCurrent;
}
@end

FreeDOGameCore *current;

@implementation FreeDOGameCore

// libfreedo callback
static void *fdcCallback(int procedure, void *data)
{
    switch(procedure)
    {
        case EXT_READ_ROMS:
        {
            memcpy(data, current->biosRom1Copy, ROM1_SIZE);
            void *biosRom2Dest = (void*)((intptr_t)data + ROM2_SIZE);
            memcpy(biosRom2Dest, current->biosRom2Copy, ROM2_SIZE);
            
            break;
        }
        case EXT_READ_NVRAM:
            break;
        case EXT_WRITE_NVRAM:
            break;
        case EXT_SWAPFRAME:
        {
            current->isSwapFrameSignaled = YES;
            return current->frame;
        }
        case EXT_PUSH_SAMPLE:
        {
            current->sampleBuffer[current->sampleCurrent] = (uintptr_t)data;
            current->sampleCurrent++;
            if(current->sampleCurrent >= TEMP_BUFFER_SIZE)
            {
                current->sampleCurrent = 0;
                [[current ringBufferAtIndex:0] write:current->sampleBuffer maxLength:sizeof(int32_t) * TEMP_BUFFER_SIZE];
                memset(current->sampleBuffer, 0, sizeof(int32_t) * TEMP_BUFFER_SIZE);
            }
            
            break;
        }
        case EXT_GET_PBUSLEN:
            return (void*)16;
        case EXT_GETP_PBUSDATA:
        {
            // Set up raw data to return
            unsigned char *pbusData;
            pbusData = (unsigned char *)malloc(sizeof(unsigned char)*16);
            
            pbusData[0x0] = 0x00;
            pbusData[0x1] = 0x48;
            pbusData[0x2] = CalculateDeviceLowByte(0);
            pbusData[0x3] = CalculateDeviceHighByte(0);
            pbusData[0x4] = CalculateDeviceLowByte(2);
            pbusData[0x5] = CalculateDeviceHighByte(2);
            pbusData[0x6] = CalculateDeviceLowByte(1);
            pbusData[0x7] = CalculateDeviceHighByte(1);
            pbusData[0x8] = CalculateDeviceLowByte(4);
            pbusData[0x9] = CalculateDeviceHighByte(4);
            pbusData[0xA] = CalculateDeviceLowByte(3);
            pbusData[0xB] = CalculateDeviceHighByte(3);
            pbusData[0xC] = 0x00;
            pbusData[0xD] = 0x80;
            pbusData[0xE] = CalculateDeviceLowByte(5);
            pbusData[0xF] = CalculateDeviceHighByte(5);
            
            return pbusData;
        }
        case EXT_KPRINT:
            break;
        case EXT_FRAMETRIGGER_MT:
        {
            current->isSwapFrameSignaled = YES;
            _freedo_Interface(FDP_DO_FRAME_MT, current->frame);
            
            break;
        }
        case EXT_READ2048:
            [current readSector:current->currentSector toBuffer:(uint8_t*)data];
            break;
        case EXT_GET_DISC_SIZE:
            return (void *)(intptr_t)current->sectorCount;
        case EXT_ON_SECTOR:
            current->currentSector = (intptr_t)data;
            break;
        case EXT_ARM_SYNC:
            //[current fdcCallbackArmSync:(intptr_t)data];
            NSLog(@"fdcCallback EXT_ARM_SYNC");
            break;
            
        default:
            break;
    }
    return (void*)0;
}

static void loadSaveFile(const char* path)
{
    FILE *file;
    
    file = fopen(path, "rb");
    if ( !file )
    {
        return;
    }
    
    size_t size = NVRAM_SIZE;
    void *data = _freedo_Interface(FDP_GETP_NVRAM, (void*)0);
    
    if (size == 0 || !data)
    {
        fclose(file);
        return;
    }
    
    int rc = fread(data, sizeof(uint8_t), size, file);
    if ( rc != size )
    {
        NSLog(@"Couldn't load save file.");
    }
    
    NSLog(@"Loaded save file: %s", path);
    
    fclose(file);
}

static void writeSaveFile(const char* path)
{
    size_t size = NVRAM_SIZE;
    void *data = _freedo_Interface(FDP_GETP_NVRAM, (void*)0);
    
    if(data != NULL && size > 0)
    {
        FILE *file = fopen(path, "wb");
        if(file != NULL)
        {
            NSLog(@"Saving NVRAM %s. Size: %d bytes.", path, (int)size);
            if(fwrite(data, sizeof(uint8_t), size, file) != size)
                NSLog(@"Did not save file properly.");
            fclose(file);
        }
    }
}

- (id)init
{
    if((self = [super init]))
    {
        current = self;
    }
    
    return self;
}

- (void)dealloc
{
    free(videoBuffer);
}

#pragma mark Execution
- (BOOL)loadFileAtPath:(NSString *)path error:(NSError **)error
{
    romName = [path copy];
    
    NSString *isoPath;
    NSError *errorCue;
    
    currentSector = 0;
    sampleCurrent = 0;
    memset(sampleBuffer, 0, sizeof(int32_t) * TEMP_BUFFER_SIZE);
    
    NSString *cue = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&errorCue];
    
    const char *cueCString = [cue UTF8String];
    Cd *cd = cue_parse_string(cueCString);
    NSLog(@"CUE file found and parsed");
    if (cd_get_ntrack(cd)!=1)
    {
        NSLog(@"Cue file found, but the number of tracks within was not 1.");
        return NO;
    }
    
    Track *track = cd_get_track(cd, 1);
    isoMode = (TrackMode)track_get_mode(track);
    
    if ((isoMode!=MODE_MODE1&&isoMode!=MODE_MODE1_RAW))
    {
        NSLog(@"Cue file found, but the track within was not in the right format (should be BINARY and Mode1+2048 or Mode1+2352)");
        return NO;
    }
    
    NSString *isoTrack = [NSString stringWithUTF8String:track_get_filename(track)];
    isoPath = [path stringByReplacingOccurrencesOfString:[path lastPathComponent] withString:isoTrack];
    
    isoStream = [NSFileHandle fileHandleForReadingAtPath:isoPath];
    
    uint8_t sectorZero[2048];
    [self readSector:0 toBuffer:sectorZero];
    VolumeHeader *header = (VolumeHeader*)sectorZero;
    sectorCount = (int)reverseBytes(header->blockCount);
    NSLog(@"Sector count is %d", sectorCount);

    // init libfreedo
    [self loadBIOSes];
    [self initVideo];
    
    memset(sampleBuffer, 0, sizeof(int32_t) * TEMP_BUFFER_SIZE);
    
    _freedo_Interface(FDP_INIT, (void*)*fdcCallback);
    
    // init NVRAM
    memcpy(_freedo_Interface(FDP_GETP_NVRAM, (void*)0), nvramhead, sizeof(nvramhead));
    
    // load NVRAM save file
    NSString *extensionlessFilename = [[path lastPathComponent] stringByDeletingPathExtension];
    NSString *batterySavesDirectory = [current batterySavesDirectoryPath];

    if([batterySavesDirectory length] != 0)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];

        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];

        loadSaveFile([filePath UTF8String]);
    }
    
    // Begin per-game hacks
    // First check if we find these bytes at offset 0x0 found in some dumps
    uint8_t bytes[] = { 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x02, 0x00, 0x01 };
    [isoStream seekToFileOffset: 0x0];
    NSData *dataTrackBuffer = [isoStream readDataOfLength: 16];
    NSData *dataCompare = [[NSData alloc] initWithBytes:bytes length:sizeof(bytes)];
    BOOL bytesFound = [dataTrackBuffer isEqualToData:dataCompare];
    
    [isoStream seekToFileOffset: bytesFound ? 0x10 : 0x0];
    dataTrackBuffer = [isoStream readDataOfLength: 16];
    
    // TODO: build this out into a dict with hacks and 'fix_bit_' types for known games
    uint8_t checkbytes[] = { 0xbb, 0x26, 0x8b, 0xf0, 0xdd, 0xe9, 0x70, 0x16, 0x9b, 0xaa, 0x50, 0x7f, 0x0c, 0x6f, 0xea, 0x98 }; // Samurai Shodown EU-US
    dataCompare = [[NSData alloc] initWithBytes:checkbytes length:sizeof(bytes)];
    [isoStream seekToFileOffset: bytesFound ? 0xA20 : 0x8E0];
    dataTrackBuffer = [isoStream readDataOfLength: 16];
    
    if ([dataTrackBuffer isEqualToData:dataCompare])
        _freedo_Interface(FDP_SET_FIX_MODE, (void*)FIX_BIT_GRAPHICS_STEP_Y); // Fixes Samurai Shodown backgrounds
    
    return YES;
}

- (void)executeFrame
{
    [self executeFrameSkippingFrame:NO];
}

- (void)executeFrameSkippingFrame:(BOOL)skip
{
    _freedo_Interface(FDP_DO_EXECFRAME, frame); // FDP_DO_EXECFRAME_MT ?
}

- (void)resetEmulation
{
    // looks like libfreedo cannot do this :|
}

- (void)stopEmulation
{
    // save NVRAM file
    NSString *extensionlessFilename = [[romName lastPathComponent] stringByDeletingPathExtension];
    NSString *batterySavesDirectory = [self batterySavesDirectoryPath];
    
    if([batterySavesDirectory length] != 0)
    {
        [[NSFileManager defaultManager] createDirectoryAtPath:batterySavesDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
        
        NSString *filePath = [batterySavesDirectory stringByAppendingPathComponent:[extensionlessFilename stringByAppendingPathExtension:@"sav"]];
        
        writeSaveFile([filePath UTF8String]);
    }
    
    _freedo_Interface(FDP_DESTROY, (void*)0);
    [isoStream closeFile];
    [super stopEmulation];
}

- (NSTimeInterval)frameInterval
{
    return 60;
}

- (void)readSector:(uint)sectorNumber toBuffer:(uint8_t*)buffer
{
    if(isoMode==MODE_MODE1_RAW)
    {
        [isoStream seekToFileOffset:2352 * sectorNumber + 0x10];
    }
    else
    {
        [isoStream seekToFileOffset:2048 * sectorNumber];
    }
    NSData *data = [isoStream readDataOfLength:2048];
    memcpy(buffer, [data bytes], 2048);
}

#pragma mark Video
- (const void *)videoBuffer
{
    if(isSwapFrameSignaled)
    {
        if(fver2==fver1)
        {
            isSwapFrameSignaled = NO;
            struct BitmapCrop bmpcrop;
            ScalingAlgorithm sca;
            int rw, rh;
            Get_Frame_Bitmap((VDLFrame *)frame, videoBuffer, 0, &bmpcrop, videoWidth, videoHeight, false, true, false, sca, &rw, &rh);
            fver1++;
        }
    }
    fver2=fver1;
    return videoBuffer;
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, videoWidth, videoHeight);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(videoWidth, videoHeight);
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

#pragma mark - Audio
- (double)audioSampleRate
{
    return 44100;
}

- (NSUInteger)channelCount
{
    return 2;
}

#pragma mark - Save States
- (BOOL)saveStateToFileAtPath:(NSString *)fileName
{
    size_t size = (uintptr_t)_freedo_Interface(FDP_GET_SAVE_SIZE, (void*)0);
    void *data = malloc(sizeof(uintptr_t)*size);
    _freedo_Interface(FDP_DO_SAVE, data);
    NSData *saveData = [NSData dataWithBytesNoCopy:data length:size freeWhenDone:YES];
    NSLog(@"Game saved, length in bytes: %lu", saveData.length);
    
    return [saveData writeToFile:fileName atomically:NO];
}

- (BOOL)loadStateFromFileAtPath:(NSString *)fileName
{
    NSData *saveData = [NSData dataWithContentsOfFile:fileName];
    size_t size = sizeof(uintptr_t)*saveData.length;
    void *loadBuffer = malloc(size);
    [saveData getBytes:loadBuffer];
    
    return _freedo_Interface(FDP_DO_LOAD, loadBuffer)!=0;
}

#pragma mark - Input
- (oneway void)didPush3DOButton:(OE3DOButton)button forPlayer:(NSUInteger)player
{
    player--;
    
    switch(button)
    {
        case OE3DOButtonA:
            internal_input_state[0].buttons|=INPUTBUTTONA;
            break;
        case OE3DOButtonB:
            internal_input_state[0].buttons|=INPUTBUTTONB;
            break;
        case OE3DOButtonC:
            internal_input_state[0].buttons|=INPUTBUTTONC;
            break;
        case OE3DOButtonX:
            internal_input_state[0].buttons|=INPUTBUTTONX;
            break;
        case OE3DOButtonP:
            internal_input_state[0].buttons|=INPUTBUTTONP;
            break;
        case OE3DOButtonLeft:
            internal_input_state[0].buttons|=INPUTBUTTONLEFT;
            break;
        case OE3DOButtonRight:
            internal_input_state[0].buttons|=INPUTBUTTONRIGHT;
            break;
        case OE3DOButtonUp:
            internal_input_state[0].buttons|=INPUTBUTTONUP;
            break;
        case OE3DOButtonDown:
            internal_input_state[0].buttons|=INPUTBUTTONDOWN;
            break;
        case OE3DOButtonL:
            internal_input_state[0].buttons|=INPUTBUTTONL;
            break;
        case OE3DOButtonR:
            internal_input_state[0].buttons|=INPUTBUTTONR;
            break;
            
        default:
            break;
    }
}

- (oneway void)didRelease3DOButton:(OE3DOButton)button forPlayer:(NSUInteger)player
{
    player--;
    
    switch(button)
    {
        case OE3DOButtonA:
            internal_input_state[0].buttons&=~INPUTBUTTONA;
            break;
        case OE3DOButtonB:
            internal_input_state[0].buttons&=~INPUTBUTTONB;
            break;
        case OE3DOButtonC:
            internal_input_state[0].buttons&=~INPUTBUTTONC;
            break;
        case OE3DOButtonX:
            internal_input_state[0].buttons&=~INPUTBUTTONX;
            break;
        case OE3DOButtonP:
            internal_input_state[0].buttons&=~INPUTBUTTONP;
            break;
        case OE3DOButtonLeft:
            internal_input_state[0].buttons&=~INPUTBUTTONLEFT;
            break;
        case OE3DOButtonRight:
            internal_input_state[0].buttons&=~INPUTBUTTONRIGHT;
            break;
        case OE3DOButtonUp:
            internal_input_state[0].buttons&=~INPUTBUTTONUP;
            break;
        case OE3DOButtonDown:
            internal_input_state[0].buttons&=~INPUTBUTTONDOWN;
            break;
        case OE3DOButtonL:
            internal_input_state[0].buttons&=~INPUTBUTTONL;
            break;
        case OE3DOButtonR:
            internal_input_state[0].buttons&=~INPUTBUTTONR;
            break;
            
        default:
            break;
    }
}

int CheckDownButton(int deviceNumber,int button)
{
    if(internal_input_state[deviceNumber].buttons&button)
        return 1;
    else
        return 0;
}

char CalculateDeviceLowByte(int deviceNumber)
{
    char returnValue = 0;
    
    returnValue |= 0x01 & 0; // unknown
    returnValue |= 0x02 & 0; // unknown
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONL) ? (char)0x04 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONR) ? (char)0x08 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONX) ? (char)0x10 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONP) ? (char)0x20 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONC) ? (char)0x40 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONB) ? (char)0x80 : (char)0;
    
    return returnValue;
}

char CalculateDeviceHighByte(int deviceNumber)
{
    char returnValue = 0;
    
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONA)     ? (char)0x01 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONLEFT)  ? (char)0x02 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONRIGHT) ? (char)0x04 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONUP)    ? (char)0x08 : (char)0;
    returnValue |= CheckDownButton(deviceNumber, INPUTBUTTONDOWN)  ? (char)0x10 : (char)0;
    returnValue |= 0x20 & 0; // unknown
    returnValue |= 0x40 & 0; // unknown
    returnValue |= 0x80; // This last bit seems to indicate power and/or connectivity.
    
    return returnValue;
}

#pragma mark - FreeDoInterface
//TODO: investigate these
//-(void*)fdcGetPointerRAM
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_GETP_RAMS datum:(void*)0];
//}
//
//-(void*)fdcGetPointerROM
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_GETP_ROMS datum:(void*)0];
//}
//
//-(void*)fdcGetPointerProfile
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_GETP_PROFILE datum:(void*)0];
//}
//
//-(void)fdcDoExecuteFrameMultitask:(void*)vdlFrame
//{
//    [self _freedoActionWithInterfaceFunction:FDP_DO_EXECFRAME_MT datum:vdlFrame];
//}
//
//-(void*)fdcSetArmClock:(int)clock
//{
//    //untested!
//    return [self _freedoActionWithInterfaceFunction:FDP_SET_ARMCLOCK datum:(void*) clock];
//}
//
//-(void*)fdcSetFixMode:(int)fixMode
//{
//    return [self _freedoActionWithInterfaceFunction:FDP_SET_FIX_MODE datum:(void*) fixMode];
//}

#pragma mark - Helpers

- (void)initVideo
{
    if(videoBuffer)
        free(videoBuffer);
    
    //HightResMode = 1;
    videoWidth = 320;
    videoHeight = 240;
    videoBuffer = (uint32_t*)malloc(videoWidth * videoHeight * 4);
    frame = (VDLFrame*)malloc(sizeof(VDLFrame));
    memset(frame, 0, sizeof(VDLFrame));
    fver2=fver1=0;
}

- (void)loadBIOSes
{
    NSString *rom1Path = [[self biosDirectoryPath] stringByAppendingPathComponent:@"panafz10.bin"];
    NSData *data = [NSData dataWithContentsOfFile:rom1Path];
    NSUInteger len = [data length];
    assert(len==ROM1_SIZE);
    biosRom1Copy = (unsigned char *)malloc(len);
    memcpy(biosRom1Copy, [data bytes], len);
    
    // "ROM 2 Japanese Character ROM" / Set it if we find it. It's not requiered for soem JAP games. We still have to init the memory tho
    NSString *rom2Path = [[self biosDirectoryPath] stringByAppendingPathComponent:@"rom2.rom"];
    data = [NSData dataWithContentsOfFile:rom2Path];
    if(data)
    {
        len = [data length];
        assert(len==ROM2_SIZE);
        biosRom2Copy = (unsigned char *)malloc(len);
        memcpy(biosRom2Copy, [data bytes], len);
    }
    else
    {
        biosRom2Copy = (unsigned char *)malloc(len);
        memset(biosRom2Copy, 0, len);
    }
}

static uint32_t reverseBytes(uint32_t value)
{
    return (value & 0x000000FFU) << 24 | (value & 0x0000FF00U) << 8 | (value & 0x00FF0000U) >> 8 | (value & 0xFF000000U) >> 24;
}

@end
