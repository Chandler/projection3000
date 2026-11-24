#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <Syphon/Syphon.h>
int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
        SyphonServerDirectory *directory = SyphonServerDirectory.sharedDirectory;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        SyphonMetalClient *client = nil;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
        while (deadline.timeIntervalSinceNow > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            if (!client) {
                for (NSDictionary *server in directory.servers) {
                    NSString *requested = NSProcessInfo.processInfo.environment[@"PATCH_SYPHON_NAME"];
                    NSString *name = server[SyphonServerDescriptionNameKey];
                    BOOL matches = requested ? [name isEqualToString:requested] : ([name isEqualToString:@"Patch Integration Syphon"] || [name hasPrefix:@"Patch Integration Syphon · "]);
                    if (matches) {
                        client = [[SyphonMetalClient alloc] initWithServerDescription:server device:device options:nil newFrameHandler:nil];
                        break;
                    }
                }
            }
            if (client.hasNewFrame) {
                id<MTLTexture> frame = [client newFrameImage];
                if (!frame) continue;
                NSUInteger stride = ((frame.width*4+255)/256)*256;
                id<MTLBuffer> pixels = [device newBufferWithLength:stride*frame.height options:MTLResourceStorageModeShared];
                id<MTLCommandBuffer> command = [[device newCommandQueue] commandBuffer];
                id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
                [blit copyFromTexture:frame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(frame.width,frame.height,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:pixels.length];
                [blit endEncoding]; [command commit]; [command waitUntilCompleted];
                uint8_t *bytes = pixels.contents; unsigned long total = 0;
                for (NSUInteger y=0;y<frame.height;y+=17) for (NSUInteger x=0;x<frame.width;x+=17) { NSUInteger i=y*stride+x*4; total += bytes[i]+bytes[i+1]+bytes[i+2]; }
                if (frame.width >= 64 && total > 1000) { printf("PASS Syphon receiver: %lu x %lu, nonblack Metal texture\n",(unsigned long)frame.width,(unsigned long)frame.height); [client stop]; return 0; }
            }
        }
        fprintf(stderr,"FAIL Syphon receiver: no usable frames\n"); return 1;
    }
}
