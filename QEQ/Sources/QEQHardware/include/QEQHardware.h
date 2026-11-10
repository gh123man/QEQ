#pragma once
#include <stddef.h>
#include <stdint.h>
int qeq_lz4_compress(const void * _Nullable input, int size, void * _Nullable output, int capacity);
int qeq_lz4_decompress(const void * _Nullable input, int size, void * _Nullable output, int capacity);
void * _Nullable qeq_lz4_encoder_create(void);
void qeq_lz4_encoder_destroy(void * _Nullable encoder);
int qeq_lz4_encoder_compress(void * _Nullable encoder, const void * _Nullable input, int size,
                            void * _Nullable output, int capacity);
int qeq_lz4_compress_bound(int size);
uint32_t qeq_display_crc32(const void * _Nullable input, size_t size, uint32_t seed);
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
NS_ASSUME_NONNULL_BEGIN
@interface QEQUSBDevice : NSObject
@property(nonatomic, readonly) uint64_t registryID;
@property(nonatomic, readonly) NSString *serial;
@property(nonatomic, readonly) NSString *productName;
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
- (NSString *)diagnosticStatus;
- (void)close;
@end
NS_ASSUME_NONNULL_END
#endif
