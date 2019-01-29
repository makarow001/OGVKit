//
//  OGVAudioEncoder.h
//  OGVKit
//
//  Copyright (c) 2016-2018 Brion Vibber. All rights reserved.
//

#import "OGVKit.h"

const NSString *OGVAudioEncoderOptionsBitrateKey = @"audioBitrate";

@implementation OGVAudioEncoder

-(instancetype)initWithFormat:(OGVAudioFormat *)format
                      options:(NSDictionary *)options
{
    self = [self init];
    if (self) {
        _format = format;
        _options = options;
        _packets = [[OGVQueue alloc] init];
    }
    return self;
}

-(void)encodeAudio:(OGVAudioBuffer *)buffer
{
    [OGVKit.singleton.logger errorWithFormat:@"encoding not implemented"];
}

-(void)close
{
    // no-op
}

@end
