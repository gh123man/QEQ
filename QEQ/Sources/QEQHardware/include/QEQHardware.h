#pragma once
#include <stddef.h>
#include <stdint.h>
int qeq_lz4_compress(const void * _Nullable input, int size, void * _Nullable output, int capacity);
int qeq_lz4_decompress(const void * _Nullable input, int size, void * _Nullable output, int capacity);
uint32_t qeq_display_crc32(const void * _Nullable input, size_t size, uint32_t seed);
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
NS_ASSUME_NONNULL_BEGIN
@interface QEQUSBDevice : NSObject
@property(nonatomic, readonly) uint64_t registryID;
@property(nonatomic, readonly) NSString *serial;
@property(nonatomic, readonly) io_service_t service;
@end
@interface QEQUSBDiscovery : NSObject
- (void)start:(void (^)(NSArray<QEQUSBDevice *> *devices))handler;
- (void)stop;
@end
@interface QEQUSBEndpoint : NSObject
- (nullable instancetype)initWithDevice:(QEQUSBDevice *)device error:(NSError **)error;
- (BOOL)write:(NSData *)data error:(NSError **)error;
- (nullable NSData *)readWithTimeout:(double)timeout error:(NSError **)error;
- (void)close;
@end
NS_ASSUME_NONNULL_END
#endif
