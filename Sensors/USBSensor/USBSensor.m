//
//  USBSensor.m
//  MarcoPolo
//
//  Created by David Symonds on 15/06/08.
//

#import <IOKit/IOCFPlugIn.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>
#import <IOKit/usb/USB.h>

#import "USBDevice.h"
#import "USBSensor.h"
#import "USBVendorDB.h"


@interface USBSensor (Private)

- (void)devAdded:(io_iterator_t)iterator;
- (void)enumerateAll;
- (void)devRemoved:(io_iterator_t)iterator;
+ (NSString *)usbVendorById:(UInt16)vendor_id;
+ (BOOL)usbDetailsForDevice:(io_service_t *)device outVendor:(UInt16 *)vendor_id outProduct:(UInt16 *)product_id;

@end

#pragma mark -
#pragma mark C callbacks

static void devAdded(void *ref, io_iterator_t iterator)
{
	USBSensor *mon = (USBSensor *) ref;
	[mon devAdded:iterator];
}

static void devRemoved(void *ref, io_iterator_t iterator)
{
	USBSensor *mon = (USBSensor *) ref;
	[mon devRemoved:iterator];
}

#pragma mark -

@implementation USBSensor

- (id)init
{
	if (!(self = [super init]))
		return nil;

	lock_ = [[NSLock alloc] init];
	devices_ = [[NSMutableSet alloc] init];
	runLoopSource_ = nil;

	return self;
}

- (void)dealloc
{
	[lock_ release];
	[devices_ release];
	[super dealloc];
}

- (NSString *)name
{
	return @"USB";
}

- (BOOL)isMultiValued
{
	return YES;
}

- (void)start
{
	// Load the vendor DB early.
	[USBVendorDB sharedUSBVendorDB];

	notificationPort_ = IONotificationPortCreate(kIOMasterPortDefault);
	runLoopSource_ = IONotificationPortGetRunLoopSource(notificationPort_);
	CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource_, kCFRunLoopDefaultMode);

	CFDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
	matchDict = CFRetain(matchDict);	// we use it twice

	IOServiceAddMatchingNotification(notificationPort_, kIOMatchedNotification,
					 matchDict, devAdded, (void *) self,
					 &addedIterator_);
	IOServiceAddMatchingNotification(notificationPort_, kIOTerminatedNotification,
					 matchDict, devRemoved, (void *) self,
					 &removedIterator_);

	// Prime notifications to get the currently connected devices
	[self devAdded:addedIterator_];
	[self devRemoved:removedIterator_];
}

- (void)stop
{
	CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource_, kCFRunLoopDefaultMode);
	IONotificationPortDestroy(notificationPort_);
	IOObjectRelease(addedIterator_);
	IOObjectRelease(removedIterator_);
	runLoopSource_ = nil;

	[self willChangeValueForKey:@"value"];
	[devices_ removeAllObjects];
	[self didChangeValueForKey:@"value"];
}

- (BOOL)running
{
	return runLoopSource_ != nil;
}

- (NSObject *)value
{
	[lock_ lock];

	NSMutableArray *array = [NSMutableArray arrayWithCapacity:[devices_ count]];
	NSEnumerator *en = [devices_ objectEnumerator];
	USBDevice *device;
	while ((device = [en nextObject])) {
		NSDictionary *data = [NSDictionary dictionaryWithObjectsAndKeys:
				      [device vendorID], @"vendor_id",
				      [device productID], @"product_id", nil];
		[array addObject:[NSDictionary dictionaryWithObjectsAndKeys:
				  data, @"data",
				  [device description], @"description", nil]];
	}

	[lock_ unlock];

	return array;
}

- (void)devAdded:(io_iterator_t)iterator
{
	// Devices that we ignore.
	static const struct {
		UInt16 vendor_id, product_id;
	} internal_devices[] = {
		{ 0x05AC, 0x0217 },		// (Apple) Internal Keyboard/Trackpad
		{ 0x05AC, 0x021A },		// (Apple) Apple Internal Keyboard/Trackpad
		{ 0x05AC, 0x1003 },		// (Apple) Hub in Apple Extended USB Keyboard
		{ 0x05AC, 0x8005 },		// (Apple) UHCI Root Hub Simulation
		{ 0x05AC, 0x8006 },		// (Apple) EHCI Root Hub Simulation
		{ 0x05AC, 0x8205 },		// (Apple) IOUSBWirelessControllerDevice
		{ 0x05AC, 0x8206 },		// (Apple) IOUSBWirelessControllerDevice
		{ 0x05AC, 0x8240 },		// (Apple) IR Receiver
		{ 0x05AC, 0x8242 },		// (Apple) IR Receiver
		{ 0x05AC, 0x8501 },		// (Apple) Built-in iSight
		{ 0x05AC, 0x8502 },		// (Apple) Built-in iSight
	};
	if (!iterator)
		NSLog(@"USB devAdded >> passed null io_iterator_t!");

	io_service_t device;
	int cnt = -1;
	while ((device = IOIteratorNext(iterator))) {
		++cnt;

		// Try to get device name
		NSString *device_name = nil;
		io_name_t dev_name;
		kern_return_t rc;
		if ((rc = IORegistryEntryGetName(device, dev_name)) == KERN_SUCCESS)
			device_name = [NSString stringWithUTF8String:dev_name];
		else {
			NSLog(@"IORegistryEntryGetName failed?!? (rc=0x%08x)", rc);
			device_name = NSLocalizedString(@"(Unnamed device)", @"String for unnamed devices");
		}

		// Get USB vendor ID and product ID
		UInt16 vendor_id;
		UInt16 product_id;
		if (!device)
			NSLog(@"USB devAdded >> hit null io_service_t!");
		if (![[self class] usbDetailsForDevice:&device outVendor:&vendor_id outProduct:&product_id]) {
			NSLog(@"USB >> failed getting details.", cnt);
			goto end_of_device_handling;
		}

		// Skip if it's a known internal device
		unsigned int i = sizeof(internal_devices) / sizeof(internal_devices[0]);
		while (i-- > 0) {
			if (internal_devices[i].vendor_id != vendor_id)
				continue;
			if (internal_devices[i].product_id != product_id)
				continue;
			// Found a match.
			goto end_of_device_handling;
		}

		// Lookup vendor name
		NSString *vendor_name = [[self class] usbVendorById:vendor_id];

		// Add device to the list
		NSString *desc = [device_name stringByAppendingFormat:@" (%@)", vendor_name];
		USBDevice *dev = [USBDevice deviceWithVendor:vendor_id
						     product:product_id
						 description:desc];
		[self willChangeValueForKey:@"value"];
		[lock_ lock];
		[devices_ addObject:dev];
		[lock_ unlock];
		[self didChangeValueForKey:@"value"];

end_of_device_handling:
		IOObjectRelease(device);
	}
}

- (void)enumerateAll
{
	kern_return_t kr;
	io_iterator_t iterator = 0;

	// Create matching dictionary for I/O Kit enumeration
	CFMutableDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
	kr = IOServiceGetMatchingServices(kIOMasterPortDefault, matchDict, &iterator);
	if (kr != KERN_SUCCESS)
		NSLog(@"USB enumerateAll >> IOServiceGetMatchingServices returned %d", kr);

	[self willChangeValueForKey:@"value"];
	[lock_ lock];
	[devices_ removeAllObjects];
	[lock_ unlock];
	[self devAdded:iterator];
	[self didChangeValueForKey:@"value"];

	IOObjectRelease(iterator);
}

- (void)devRemoved:(io_iterator_t)iterator
{
	// When a USB device is removed, we usually don't get its details,
	// nor can we query those details (since it's removed, duh!). Thus
	// we do the simplest thing of doing a full rescan.
	io_service_t device;
	while ((device = IOIteratorNext(iterator)))
		IOObjectRelease(device);
	[self enumerateAll];
}

// Returns a string, or the vendor_id in hexadecimal.
+ (NSString *)usbVendorById:(UInt16)vendor_id
{
	NSDictionary *db = [USBVendorDB sharedUSBVendorDB];
	NSString *vid = [NSString stringWithFormat:@"%d", vendor_id];
	NSString *name = [db valueForKey:vid];

	if (name)
		return name;

	return [NSString stringWithFormat:@"0x%04X", vendor_id];
}

// Returns true on success.
+ (BOOL)usbDetailsForDevice:(io_service_t *)device outVendor:(UInt16 *)vendor_id outProduct:(UInt16 *)product_id
{
	IOReturn rc;
	NSMutableDictionary *props;

	rc = IORegistryEntryCreateCFProperties(*device, (CFMutableDictionaryRef *) &props,
					       kCFAllocatorDefault, kNilOptions);
	if ((rc != kIOReturnSuccess) || !props)
		return NO;
	*vendor_id = [[props valueForKey:@"idVendor"] intValue];
	*product_id = [[props valueForKey:@"idProduct"] intValue];
	[props release];

	return YES;
}

@end
