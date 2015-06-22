//
//  OGVDecoderWebM.m
//  OGVKit
//
//  Created by Brion on 6/17/15.
//  Copyright (c) 2015 Brion Vibber. All rights reserved.
//

#import "OGVKit.h"
#import "OGVDecoderWebM.h"

#include <nestegg/nestegg.h>

#ifdef OGVKIT_HAVE_VP8_DECODER
#define VPX_CODEC_DISABLE_COMPAT 1
#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>
#endif

#ifdef OGVKIT_HAVE_VORBIS_DECODER
#include <ogg/ogg.h>
#include <vorbis/codec.h>
#endif

#define PACKET_QUEUE_MAX 128

static void logCallback(nestegg *context, unsigned int severity, char const * format, ...)
{
    if (severity >= NESTEGG_LOG_INFO) {
        va_list args;
        va_start(args, format);
        vprintf(format, args);
        va_end(args);
    }
}

static int readCallback(void * buffer, size_t length, void *userdata)
{
    OGVDecoderWebM *decoder = (__bridge OGVDecoderWebM *)userdata;
    OGVInputStream *stream = decoder.inputStream;
    NSData *data = [stream readBytes:length blocking:YES];
    if (data) {
        assert([data length] <= length);
        memcpy(buffer, [data bytes], [data length]);
        return 1;
    } else {
        return 0;
    }
}

static int seekCallback(int64_t offset, int whence, void * userdata)
{
    // @todo implement on OGVInputStream
    abort();
    return -1;
}

static int64_t tellCallback(void * userdata)
{
    OGVDecoderWebM *decoder = (__bridge OGVDecoderWebM *)userdata;
    OGVInputStream *stream = decoder.inputStream;
    return (int64_t)stream.bytePosition;
}

static nestegg_packet *packet_queue_shift(nestegg_packet **queue, unsigned int *count)
{
    if (*count > 0) {
        nestegg_packet *first = queue[0];
        memcpy(&(queue[0]), &(queue[1]), sizeof(nestegg_packet *) * (*count - 1));
        (*count)--;
        return first;
    } else {
        return NULL;
    }
}

#ifdef OGVKIT_HAVE_VORBIS_DECODER
static void data_to_ogg_packet(unsigned char *data, size_t data_size, ogg_packet *dest)
{
    dest->packet = data;
    dest->bytes = data_size;
    dest->b_o_s = 0;
    dest->e_o_s = 0;
    dest->granulepos = 0; // ?
    dest->packetno = 0; // ?
}

static void ne_packet_to_ogg_packet(nestegg_packet *src, ogg_packet *dest)
{
    unsigned int count;
    nestegg_packet_count(src, &count);
    assert(count == 1);
    
    unsigned char *data;
    size_t data_size;
    nestegg_packet_data(src, 0, &data, &data_size);
    
    data_to_ogg_packet(data, data_size, dest);
}
#endif

@implementation OGVDecoderWebM
{
    nestegg        *demuxContext;
    nestegg_io      ioCallbacks;
    char           *bufferQueue;
    size_t          bufferSize;
    uint64_t        bufferBytesRead;
    
    unsigned int    videoTrack;
    int             videoCodec;
    unsigned int    videoPacketCount;
    nestegg_packet *videoPackets[PACKET_QUEUE_MAX];
    
    unsigned int    audioTrack;
    int             audioCodec;
    unsigned int    audioPacketCount;
    nestegg_packet *audioPackets[PACKET_QUEUE_MAX];
    

#ifdef OGVKIT_HAVE_VP8_DECODER
    vpx_codec_ctx_t    vpxContext;
    vpx_codec_iface_t *vpxDecoder;
#endif
    
    /* single frame video buffering */
    int64_t           videobufGranulepos;  // @todo reset with TH_CTL_whatver on seek
    double            videobufTime;         // time seen on actual decoded frame
    int64_t           keyframeGranulepos;  //
    double            keyframeTime;        // last-keyframe time seen on actual decoded frame
    
    int64_t           audiobufGranulepos; /* time position of last sample */
    double            audiobufTime;

#ifdef OGVKIT_HAVE_VORBIS_DECODER
    /* Audio decode state */
    ogg_packet        audioPacket;
    int               vorbisHeaders;
    int               vorbisProcessingHeaders;
    vorbis_info       vorbisInfo;
    vorbis_dsp_state  vorbisDspState;
    vorbis_block      vorbisBlock;
    vorbis_comment    vorbisComment;
#endif

    OGVAudioBuffer *queuedAudio;
    OGVVideoBuffer *queuedFrame;
}

enum AppState {
    STATE_BEGIN,
    STATE_DECODING
} appState;

-(instancetype)init
{
    self = [super init];
    if (self) {
        //
        appState = STATE_BEGIN;
        videoCodec = -1;
        audioCodec = -1;

        ioCallbacks.read = readCallback;
        ioCallbacks.seek = seekCallback;
        ioCallbacks.tell = tellCallback;
        ioCallbacks.userdata = (__bridge void *)self;
        
#ifdef OGVKIT_HAVE_VORBIS_DECODER
        /* init supporting Vorbis structures needed in header parsing */
        vorbis_info_init(&vorbisInfo);
        vorbis_comment_init(&vorbisComment);
#endif
    }
    return self;
}

-(BOOL)processBegin
{
    if (nestegg_init(&demuxContext, ioCallbacks, logCallback, -1) < 0) {
        NSLog(@"nestegg_init failed");
        return NO;
    }
    
    // Look through the tracks finding our video and audio
    BOOL hasVideo = NO;
    BOOL hasAudio = NO;
    unsigned int tracks;
    if (nestegg_track_count(demuxContext, &tracks) < 0) {
        tracks = 0;
    }
    for (unsigned int track = 0; track < tracks; track++) {
        int trackType = nestegg_track_type(demuxContext, track);
        int codec = nestegg_track_codec_id(demuxContext, track);
        
        if (trackType == NESTEGG_TRACK_VIDEO && !hasVideo) {
#ifdef OGVKIT_HAVE_VP8_DECODER
            if (codec == NESTEGG_CODEC_VP8 /* || codec == NESTEGG_CODEC_VP9 */) {
                hasVideo = YES;
                videoTrack = track;
                videoCodec = codec;
            }
#endif
        }
        
        if (trackType == NESTEGG_TRACK_AUDIO && !hasAudio) {
#ifdef OGVKIT_HAVE_VORBIS_DECODER
            if (codec == NESTEGG_CODEC_VORBIS /* || codec == NESTEGG_CODEC_OPUS */) {
                hasAudio = YES;
                audioTrack = track;
                audioCodec = codec;
            }
#endif
        }
    }
    
    if (hasVideo) {
        nestegg_video_params videoParams;
        if (nestegg_track_video_params(demuxContext, videoTrack, &videoParams) < 0) {
            // failed! something is wrong...
            return NO;
        } else {
#ifdef OGVKIT_HAVE_VP8_DECODER
            if (videoCodec == NESTEGG_CODEC_VP8) {
                vpxDecoder = vpx_codec_vp8_dx();
            } else if (videoCodec == NESTEGG_CODEC_VP9) {
                vpxDecoder = vpx_codec_vp9_dx();
            }
            vpx_codec_dec_init(&vpxContext, vpxDecoder, NULL, 0);

            self.videoFormat = [[OGVVideoFormat alloc] init];
            self.videoFormat.frameWidth = videoParams.width;
            self.videoFormat.frameHeight = videoParams.height;
            self.videoFormat.pictureWidth = videoParams.display_width;
            self.videoFormat.pictureHeight = videoParams.display_height;
            self.videoFormat.pictureOffsetX = videoParams.crop_left;
            self.videoFormat.pictureOffsetY = videoParams.crop_top;
            self.videoFormat.pixelFormat = OGVPixelFormatYCbCr420; // @todo vp9 can do other formats too
#endif
        }
    }
    
    if (hasAudio) {
        nestegg_audio_params audioParams;
        if (nestegg_track_audio_params(demuxContext, audioTrack, &audioParams) < 0) {
            // failed! something is wrong
            return NO;
        } else {
#ifdef OGVKIT_HAVE_VORBIS_DECODER
            unsigned int codecDataCount;
            nestegg_track_codec_data_count(demuxContext, audioTrack, &codecDataCount);
            
            for (unsigned int i = 0; i < codecDataCount; i++) {
                unsigned char *data;
                size_t len;
                int ret = nestegg_track_codec_data(demuxContext, audioTrack, i, &data, &len);
                if (ret < 0) {
                    NSLog(@"failed to read codec data %d", i);
                    return NO;
                }
                data_to_ogg_packet(data, len, &audioPacket);
                audioPacket.b_o_s = (i == 0); // haaaaaack
                
                if (audioCodec == NESTEGG_CODEC_VORBIS) {
                    ret = vorbis_synthesis_headerin(&vorbisInfo, &vorbisComment, &audioPacket);
                    if (ret == 0) {
                        vorbisHeaders++;
                    } else {
                        NSLog(@"Invalid vorbis header? %d", ret);
                        return NO;
                    }
                }
            }
#endif
        }
    }
    
#ifdef OGVKIT_HAVE_VORBIS_DECODER
	if (vorbisHeaders) {
		vorbis_synthesis_init(&vorbisDspState, &vorbisInfo);
		vorbis_block_init(&vorbisDspState, &vorbisBlock);
		
        self.audioFormat = [[OGVAudioFormat alloc] initWithChannels:vorbisInfo.channels
                                                         sampleRate:vorbisInfo.rate];
	}
#endif

    appState = STATE_DECODING;
    self.dataReady = YES;
    self.hasAudio = hasAudio;
    self.hasVideo = hasVideo;

    return YES;
}

-(BOOL)processDecoding
{
    BOOL needData = NO;
    
    if (self.hasVideo && !self.frameReady) {
        needData = YES;
    }

    if (self.hasAudio && !self.audioReady) {
        needData = YES;
    }

    if (needData) {
        // Do the nestegg_read_packet dance until it fails to read more data,
        // at which point we ask for more. Hope it doesn't explode.
        nestegg_packet *packet = NULL;
        int ret = nestegg_read_packet(demuxContext, &packet);
        if (ret == 0) {
            // end of stream?
            return NO;
        } else if (ret > 0) {
            unsigned int track;
            nestegg_packet_track(packet, &track);
            
            if (self.hasVideo && track == videoTrack) {
                if (videoPacketCount >= PACKET_QUEUE_MAX) {
                    // that's not good
                }
                videoPackets[videoPacketCount++] = packet;
            } else if (self.hasAudio && track == audioTrack) {
                if (audioPacketCount >= PACKET_QUEUE_MAX) {
                    // that's not good
                }
                audioPackets[audioPacketCount++] = packet;
            } else {
                // throw away unknown packets
                nestegg_free_packet(packet);
            }
        }
    }
    
    return YES;
}

-(BOOL)decodeFrame
{
    nestegg_packet *packet = packet_queue_shift(videoPackets, &videoPacketCount);
    
    if (packet) {
        unsigned int chunks;
        nestegg_packet_count(packet, &chunks);
        
        uint64_t timestamp;
        nestegg_packet_tstamp(packet, &timestamp);
        videobufTime = timestamp / 1000000000.0;
        
#ifdef OGVKIT_HAVE_VP8_DECODER
        // uh, can this happen? curiouser :D
        for (unsigned int chunk = 0; chunk < chunks; ++chunk) {
            unsigned char *data;
            size_t data_size;
            nestegg_packet_data(packet, chunk, &data, &data_size);
            
            vpx_codec_decode(&vpxContext, data, (unsigned int)data_size, NULL, 1);
            // @todo check return value
        }
        // last chunk!
        vpx_codec_decode(&vpxContext, NULL, 0, NULL, 1);
        
        vpx_codec_iter_t iter = NULL;
        vpx_image_t *image = NULL;
        bool foundImage = false;
        while ((image = vpx_codec_get_frame(&vpxContext, &iter))) {
            // is it possible to get more than one at a time? ugh
            // @fixme can we have multiples really? how does this worky
            if (foundImage) {
                // skip for now
                continue;
            }
            foundImage = true;

            OGVVideoPlane *Y = [[OGVVideoPlane alloc] initWithBytes:image->planes[0]
                                                             stride:image->stride[0]
                                                              lines:self.videoFormat.lumaHeight];

            OGVVideoPlane *Cb = [[OGVVideoPlane alloc] initWithBytes:image->planes[1]
                                                              stride:image->stride[1]
                                                               lines:self.videoFormat.chromaHeight];

            OGVVideoPlane *Cr = [[OGVVideoPlane alloc] initWithBytes:image->planes[2]
                                                              stride:image->stride[2]
                                                               lines:self.videoFormat.chromaHeight];

            OGVVideoBuffer *buffer = [[OGVVideoBuffer alloc] initWithFormat:self.videoFormat
                                                                          Y:Y
                                                                         Cb:Cb
                                                                         Cr:Cr
                                                                  timestamp:videobufTime];

            queuedFrame = buffer;
        }
#endif
        
        nestegg_free_packet(packet);
        return 1; // ??
    }

	return 0;
}

-(BOOL)decodeAudio
{
    int foundSome = 0;
    
    nestegg_packet *packet = packet_queue_shift(audioPackets, &audioPacketCount);

    if (packet) {

#ifdef OGVKIT_HAVE_VORBIS_DECODER
        if (audioCodec == NESTEGG_CODEC_VORBIS) {
            ne_packet_to_ogg_packet(packet, &audioPacket);
            
            int ret = vorbis_synthesis(&vorbisBlock, &audioPacket);
            if (ret == 0) {
                vorbis_synthesis_blockin(&vorbisDspState, &vorbisBlock);
                
                float **pcm;
                int sampleCount = vorbis_synthesis_pcmout(&vorbisDspState, &pcm);
                if (sampleCount > 0) {
                    foundSome = YES;
                    queuedAudio = [[OGVAudioBuffer alloc] initWithPCM:pcm samples:sampleCount format:self.audioFormat];
                    
                    vorbis_synthesis_read(&vorbisDspState, sampleCount);
                    if (audiobufGranulepos != -1) {
                        // keep track of how much time we've decodec
                        audiobufGranulepos += sampleCount;
                        audiobufTime = (double)audiobufGranulepos / self.audioFormat.sampleRate;
                    }
                } else {
                    NSLog(@"Vorbis decoder gave an empty packet!");
                }
            } else {
                NSLog(@"Vorbis decoder failed mysteriously? %d", ret);
            }
        }
#endif
        nestegg_free_packet(packet);
    }
    
    return foundSome;
}

-(BOOL)process
{
    if (appState == STATE_BEGIN) {
        return [self processBegin];
    } else if (appState == STATE_DECODING) {
        return [self processDecoding];
    } else {
        // uhhh...
        NSLog(@"Invalid appState in -[OGVDecoderWebM process]\n");
        return NO;
    }
}


- (OGVVideoBuffer *)frameBuffer
{
    OGVVideoBuffer *buffer = queuedFrame;
    queuedFrame = nil;
    return buffer;
}

- (OGVAudioBuffer *)audioBuffer
{
    OGVAudioBuffer *buffer = queuedAudio;
    queuedAudio = nil;
    return buffer;
}

-(void)dealloc
{
#ifdef OGVKIT_HAVE_VORBIS_DECODER
    if (vorbisHeaders) {
        //ogg_stream_clear(&vorbisStreamState);
        vorbis_info_clear(&vorbisInfo);
        vorbis_dsp_clear(&vorbisDspState);
        vorbis_block_clear(&vorbisBlock);
        vorbis_comment_clear(&vorbisComment);
    }
#endif
}

#pragma mark - property getters

- (BOOL)frameReady
{
    return appState == STATE_DECODING && (videoPacketCount > 0);
}

- (BOOL)audioReady
{
    return appState == STATE_DECODING && (audioPacketCount > 0);
}

-(BOOL)seekable
{
    return self.dataReady &&
        self.inputStream.seekable &&
        demuxContext &&
        nestegg_has_cues(demuxContext);
}

-(float)duration
{
    if (demuxContext) {
        uint64_t duration_ns;
        if (nestegg_duration(demuxContext, &duration_ns) == 0) {
            return duration_ns / 1000000000.0;
        }
    }
    return INFINITY;
}

#pragma mark - class methods

+ (BOOL)canPlayType:(OGVMediaType *)mediaType
{
    if ([mediaType.minor isEqualToString:@"webm"] &&
         ([mediaType.major isEqualToString:@"audio"] ||
          [mediaType.major isEqualToString:@"video"])
        ) {

        if (mediaType.codecs) {
            int knownCodecs = 0;
            int unknownCodecs = 0;
            for (NSString *codec in mediaType.codecs) {
#ifdef OGVKIT_HAVE_VP8_DECODER
                if ([codec isEqualToString:@"vp8"]) {
                    knownCodecs++;
                    continue;
                }
#endif
#ifdef OGVKIT_HAVE_VORBIS_DECODER
                if ([codec isEqualToString:@"vorbis"]) {
                    knownCodecs++;
                    continue;
                }
#endif
                unknownCodecs++;
            }
            if (knownCodecs == 0) {
                return OGVCanPlayNo;
            }
            if (unknownCodecs > 0) {
                return OGVCanPlayNo;
            }
            // All listed codecs are ones we know. Neat!
            return OGVCanPlayProbably;
        } else {
            return OGVCanPlayMaybe;
        }
    } else {
        return OGVCanPlayNo;
    }
}

@end
