//
//  OGVAudioEncoder.h
//  OGVKit
//
//  Copyright (c) 2016 Brion Vibber. All rights reserved.
//

extern const NSString *OGVAudioEncoderOptionsBitrateKey;

@interface OGVAudioEncoder : NSObject

@property (readonly) NSString *codec;
@property (readonly) OGVAudioFormat *format;
@property (readonly) NSDictionary *options;
@property (readonly) OGVQueue *packets;
@property (readonly) NSArray *headers;

-(instancetype)initWithFormat:(OGVAudioFormat *)format
                      options:(NSDictionary *)options;

-(void)encodeAudio:(OGVAudioBuffer *)buffer;

-(void)close;

@end
