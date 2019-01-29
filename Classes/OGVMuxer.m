//
//  OGVMuxer.m
//  OGVKit
//
//  Copyright (c) 2016-2018 Brion Vibber. All rights reserved.
//

#import "OGVKit.h"

@implementation OGVMuxer

-(void)addAudioTrack:(OGVAudioEncoder *)audioEncoder
{
}

-(void)addVideoTrack:(OGVVideoEncoder *)videoEncoder
{
}

-(void)openOutputStream:(OGVOutputStream *)outputStream
{
}

-(void)appendAudioPacket:(OGVPacket *)packet
{
    [OGVKit.singleton.logger errorWithFormat:@"encoding not implemented"];
}

-(void)appendVideoPacket:(OGVPacket *)packet
{
    [OGVKit.singleton.logger errorWithFormat:@"encoding not implemented"];
}

-(void)close
{
    // no-op
}

@end
