#import "QEQHardware.h"
#import <IOUSBHost/IOUSBHost.h>

static CFMutableDictionaryRef matching(void) {
    return [IOUSBHostInterface createMatchingDictionaryWithVendorID:@0x303a productID:@0x1001
        bcdDevice:nil interfaceNumber:nil configurationValue:nil interfaceClass:@0xff
        interfaceSubclass:@0x51 interfaceProtocol:@1 speed:nil productIDArray:nil];
}
static NSError *failure(NSString *description) {
    return [NSError errorWithDomain:@"QEQ.USBDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey:description}];
}
@implementation QEQUSBDevice
- (instancetype)initWithService:(io_service_t)service {
    if ((self = [super init])) {
        _service = service; IOObjectRetain(service);
        IORegistryEntryGetRegistryEntryID(service, &_registryID);
        CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("USB Serial Number"),
            kCFAllocatorDefault, kIORegistryIterateParents | kIORegistryIterateRecursively);
        _serial = value && CFGetTypeID(value) == CFStringGetTypeID() ? [(__bridge NSString *)value copy] : @"";
        if (value) CFRelease(value);
    }
    return self;
}
- (void)dealloc { if (_service) IOObjectRelease(_service); }
@end

@interface QEQUSBDiscovery () {
    dispatch_queue_t _queue;
    IONotificationPortRef _port;
    io_iterator_t _added, _removed;
    void (^_handler)(NSArray<QEQUSBDevice *> *);
}
- (void)changed:(io_iterator_t)iterator;
@end
static void changed(void *context, io_iterator_t iterator) {
    @autoreleasepool { [(__bridge QEQUSBDiscovery *)context changed:iterator]; }
}
@implementation QEQUSBDiscovery
- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("QEQ.display.discovery", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (void)start:(void (^)(NSArray<QEQUSBDevice *> *))handler {
    dispatch_sync(_queue, ^{
        if (self->_port) return;
        self->_handler = [handler copy];
        self->_port = IONotificationPortCreate(kIOMainPortDefault);
        if (!self->_port) { self->_handler(@[]); return; }
        IONotificationPortSetDispatchQueue(self->_port, self->_queue);
        IOServiceAddMatchingNotification(self->_port, kIOFirstMatchNotification, matching(), changed,
            (__bridge void *)self, &self->_added);
        IOServiceAddMatchingNotification(self->_port, kIOTerminatedNotification, matching(), changed,
            (__bridge void *)self, &self->_removed);
        [self changed:self->_removed]; [self changed:self->_added];
    });
}
- (void)changed:(io_iterator_t)iterator {
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) IOObjectRelease(service);
    if (!_handler) return;
    io_iterator_t current = 0;
    NSMutableArray *devices = [NSMutableArray array];
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching(), &current) == KERN_SUCCESS) {
        while ((service = IOIteratorNext(current))) {
            [devices addObject:[[QEQUSBDevice alloc] initWithService:service]];
            IOObjectRelease(service);
        }
        IOObjectRelease(current);
    }
    _handler(devices);
}
- (void)stop {
    dispatch_sync(_queue, ^{
        self->_handler = nil;
        if (self->_port) { IONotificationPortSetDispatchQueue(self->_port, nil); IONotificationPortDestroy(self->_port); self->_port = nil; }
        if (self->_added) { IOObjectRelease(self->_added); self->_added = 0; }
        if (self->_removed) { IOObjectRelease(self->_removed); self->_removed = 0; }
    });
}
- (void)dealloc { [self stop]; }
@end

@implementation QEQUSBEndpoint {
    IOUSBHostInterface *_interface;
    IOUSBHostPipe *_input, *_output;
}
- (nullable instancetype)initWithDevice:(QEQUSBDevice *)device error:(NSError **)error {
    if (!(self = [super init])) return nil;
    // Claim only the vendor interface. Never seize/reset the device or open MIDI/CDC.
    _interface = [[IOUSBHostInterface alloc] initWithIOService:device.service options:IOUSBHostObjectInitOptionsNone
        queue:nil error:error interestHandler:nil];
    if (!_interface) return nil;
    const IOUSBInterfaceDescriptor *interface = _interface.interfaceDescriptor;
    const IOUSBConfigurationDescriptor *configuration = _interface.configurationDescriptor;
    if (!interface || !configuration || interface->bInterfaceClass != 0xff || interface->bInterfaceSubClass != 0x51 || interface->bInterfaceProtocol != 1) {
        if (error) *error = failure(@"Unsupported USB display interface"); [self close]; return nil;
    }
    const uint8_t *end = (const uint8_t *)configuration + OSSwapLittleToHostInt16(configuration->wTotalLength);
    const uint8_t *p = (const uint8_t *)interface + interface->bLength;
    while (p + 2 <= end && p[0] >= 2 && p + p[0] <= end && p[1] != kIOUSBDescriptorTypeInterface) {
        if (p[1] == kIOUSBDescriptorTypeEndpoint && p[0] >= sizeof(IOUSBEndpointDescriptor)) {
            const IOUSBEndpointDescriptor *ep = (const IOUSBEndpointDescriptor *)p;
            if ((ep->bmAttributes & 3) == 2) {
                IOUSBHostPipe *pipe = [_interface copyPipeWithAddress:ep->bEndpointAddress error:error];
                if (ep->bEndpointAddress & 0x80) _input = pipe; else _output = pipe;
            }
        }
        p += p[0];
    }
    if (!_input || !_output) { if (error) *error = failure(@"Missing bulk display endpoints"); [self close]; return nil; }
    return self;
}
- (BOOL)write:(NSData *)data error:(NSError **)error {
    if (!_output || data.length > 3 * 1024 * 1024) { if (error) *error = failure(@"Invalid display write"); return NO; }
    NSUInteger offset = 0;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + MIN(10, MAX(2.5, 1 + data.length / 200000.0));
    while (offset < data.length) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) { if (error) *error = failure(@"Display write timed out"); return NO; }
        NSMutableData *part = [[data subdataWithRange:NSMakeRange(offset, MIN(16384, data.length - offset))] mutableCopy];
        NSUInteger count = 0;
        if (![_output sendIORequestWithData:part bytesTransferred:&count completionTimeout:1 error:error]) return NO;
        if (!count || count > part.length) { if (error) *error = failure(@"Short display write"); return NO; }
        offset += count;
    }
    return YES;
}
- (nullable NSData *)readWithTimeout:(double)timeout error:(NSError **)error {
    if (!_input) { if (error) *error = failure(@"Display closed"); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:4096]; NSUInteger count = 0;
    if (![_input sendIORequestWithData:data bytesTransferred:&count completionTimeout:timeout error:error]) return nil;
    if (count > data.length) { if (error) *error = failure(@"Invalid USB read size"); return nil; }
    data.length = count; return data;
}
- (void)close { _input = nil; _output = nil; [_interface destroy]; _interface = nil; }
- (void)dealloc { [self close]; }
@end
