
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <sys/socket.h>
#import <sys/types.h>
#import <net/if_var.h>

static NSString * const NMDirectory =
    @"/var/mobile/Library/Preferences/NetworkMonitor";

static NSString * const NMStatePath =
    @"/var/mobile/Library/Preferences/NetworkMonitor/state.plist";

static dispatch_queue_t NMQueue;
static NSMutableDictionary *NMState;

static NSString *NMMonthKey(void) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM";
    return [formatter stringFromDate:[NSDate date]];
}

static uint64_t NMReadInterfaceBytes(NSString *wanted,
                                     uint64_t *outRX,
                                     uint64_t *outTX) {
    struct ifaddrs *interfaces = NULL;
    uint64_t rx = 0, tx = 0;

    if (getifaddrs(&interfaces) != 0) {
        if (outRX) *outRX = 0;
        if (outTX) *outTX = 0;
        return 0;
    }

    for (struct ifaddrs *ifa = interfaces; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_name || !ifa->ifa_data) continue;
        if (wanted &&
            ![wanted isEqualToString:
                [NSString stringWithUTF8String:ifa->ifa_name]]) {
            continue;
        }

        if (ifa->ifa_addr &&
            ifa->ifa_addr->sa_family == AF_LINK) {
            struct if_data *data = (struct if_data *)ifa->ifa_data;
            rx += data->ifi_ibytes;
            tx += data->ifi_obytes;
        }
    }

    freeifaddrs(interfaces);

    if (outRX) *outRX = rx;
    if (outTX) *outTX = tx;
    return rx + tx;
}

static uint64_t NMNumber(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value respondsToSelector:@selector(unsignedLongLongValue)]
        ? [value unsignedLongLongValue] : 0;
}

static void NMSave(void) {
    NSError *error = nil;
    [NSFileManager.defaultManager
        createDirectoryAtPath:NMDirectory
        withIntermediateDirectories:YES
        attributes:nil
        error:&error];

    [NMState writeToFile:NMStatePath atomically:YES];
}

static void NMUpdate(void) {
    if (!NMQueue) NMQueue = dispatch_queue_create(
        "com.networkmonitor.counter", DISPATCH_QUEUE_SERIAL);

    dispatch_async(NMQueue, ^{
        if (!NMState) {
            NMState = [NSMutableDictionary dictionaryWithContentsOfFile:NMStatePath];
            if (!NMState) NMState = [NSMutableDictionary dictionary];
        }

        uint64_t wifi = NMReadInterfaceBytes(@"en0", NULL, NULL);
        uint64_t cell = NMReadInterfaceBytes(@"pdp_ip0", NULL, NULL);

        NSString *month = NMMonthKey();
        NSString *savedMonth = NMState[@"month"];

        uint64_t oldWifi = NMNumber(NMState, @"lastWifi");
        uint64_t oldCell = NMNumber(NMState, @"lastCell");
        uint64_t lifetimeWifi = NMNumber(NMState, @"lifetimeWifi");
        uint64_t lifetimeCell = NMNumber(NMState, @"lifetimeCell");
        uint64_t monthlyWifi = NMNumber(NMState, @"monthlyWifi");
        uint64_t monthlyCell = NMNumber(NMState, @"monthlyCell");

        if (![savedMonth isEqualToString:month]) {
            monthlyWifi = 0;
            monthlyCell = 0;
            NMState[@"month"] = month;
        }

        if (wifi >= oldWifi) {
            uint64_t delta = wifi - oldWifi;
            lifetimeWifi += delta;
            monthlyWifi += delta;
        }

        if (cell >= oldCell) {
            uint64_t delta = cell - oldCell;
            lifetimeCell += delta;
            monthlyCell += delta;
        }

        NMState[@"lastWifi"] = @(wifi);
        NMState[@"lastCell"] = @(cell);
        NMState[@"lifetimeWifi"] = @(lifetimeWifi);
        NMState[@"lifetimeCell"] = @(lifetimeCell);
        NMState[@"monthlyWifi"] = @(monthlyWifi);
        NMState[@"monthlyCell"] = @(monthlyCell);

        NMSave();
    });
}

static NSString *NMFormat(uint64_t bytes) {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleBinary;
    formatter.includesUnit = YES;
    formatter.allowsNonnumericFormatting = NO;
    return [formatter stringFromByteCount:(long long)bytes];
}

@interface NMRootListController : PSListController
@end

@implementation NMRootListController

- (NSArray *)specifiers {
    NSMutableArray *items = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier
        preferenceSpecifierNamed:@"NetworkMonitor"
        target:nil
        set:nil
        get:nil
        detail:nil
        cell:PSGroupCell
        edit:nil];
    [items addObject:group];

    NSArray *rows = @[
        @[@"Wi-Fi · Tháng này", @"monthlyWifi"],
        @[@"4G/5G · Tháng này", @"monthlyCell"],
        @[@"Tổng · Tháng này", @"monthlyTotal"],
        @[@"Wi-Fi · Tích lũy", @"lifetimeWifi"],
        @[@"4G/5G · Tích lũy", @"lifetimeCell"],
        @[@"Tổng · Tích lũy", @"lifetimeTotal"]
    ];

    for (NSArray *row in rows) {
        PSSpecifier *specifier = [PSSpecifier
            preferenceSpecifierNamed:row[0]
            target:self
            set:nil
            get:@selector(readValueForSpecifier:)
            detail:nil
            cell:PSStaticTextCell
            edit:nil];

        [specifier setProperty:row[1] forKey:@"NMKey"];
        [items addObject:specifier];
    }

    PSSpecifier *reset = [PSSpecifier
        preferenceSpecifierNamed:@"Đặt lại thống kê tháng"
        target:self
        set:@selector(resetMonthly)
        get:nil
        detail:nil
        cell:PSButtonCell
        edit:nil];
    [items addObject:reset];

    return items;
}

- (id)readValueForSpecifier:(PSSpecifier *)specifier {
    NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:NMStatePath]
        ?: @{};

    NSString *key = [specifier propertyForKey:@"NMKey"];
    uint64_t wifi = NMNumber(state, [key containsString:@"Wifi"]
                                    ? key : @"monthlyWifi");
    uint64_t cell = NMNumber(state, [key containsString:@"Cell"]
                                    ? key : @"monthlyCell");

    if ([key isEqualToString:@"monthlyTotal"])
        return NMFormat(NMNumber(state, @"monthlyWifi") +
                        NMNumber(state, @"monthlyCell"));

    if ([key isEqualToString:@"lifetimeTotal"])
        return NMFormat(NMNumber(state, @"lifetimeWifi") +
                        NMNumber(state, @"lifetimeCell"));

    return NMFormat([key containsString:@"Wifi"] ? wifi : cell);
}

- (void)resetMonthly {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"Đặt lại thống kê tháng?"
            message:@"Tổng tích lũy sẽ được giữ nguyên."
            preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction
            actionWithTitle:@"Hủy"
            style:UIAlertActionStyleCancel
            handler:nil]];

        [alert addAction:[UIAlertAction
            actionWithTitle:@"Đặt lại"
            style:UIAlertActionStyleDestructive
            handler:^(__unused UIAlertAction *action) {
                dispatch_async(NMQueue, ^{
                    NMState[@"monthlyWifi"] = @0;
                    NMState[@"monthlyCell"] = @0;
                    NMState[@"month"] = NMMonthKey();
                    NMSave();
                });
                [self reloadSpecifiers];
            }]];

        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end

%ctor {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundleIdentifier
                isEqualToString:@"com.apple.Preferences"]) {
            NMUpdate();
        }
    }
}
