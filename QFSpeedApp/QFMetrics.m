#import "QFMetrics.h"

#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/processor_info.h>

static double QFCPUSample(void) {
    static processor_info_array_t previous = NULL;
    static mach_msg_type_number_t previousCount = 0;

    natural_t cpuCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) != KERN_SUCCESS) {
        return 0.0;
    }

    double total = 0.0;
    if (previous && previousCount == count) {
        for (natural_t index = 0; index < cpuCount; index++) {
            natural_t base = index * CPU_STATE_MAX;
            uint32_t busy = (info[base + CPU_STATE_USER] - previous[base + CPU_STATE_USER]) +
                            (info[base + CPU_STATE_SYSTEM] - previous[base + CPU_STATE_SYSTEM]) +
                            (info[base + CPU_STATE_NICE] - previous[base + CPU_STATE_NICE]);
            uint32_t idle = info[base + CPU_STATE_IDLE] - previous[base + CPU_STATE_IDLE];
            uint32_t all = busy + idle;
            if (all > 0) total += (double)busy / (double)all;
        }
        if (cpuCount > 0) total = total / (double)cpuCount * 100.0;
    }
    if (previous) {
        vm_deallocate(mach_task_self(), (vm_address_t)previous, previousCount * sizeof(integer_t));
    }
    previous = info;
    previousCount = count;
    return total;
}

static double QFMemorySample(void) {
    vm_statistics64_data_t statistics;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&statistics, &count) != KERN_SUCCESS) {
        return 0.0;
    }
    uint64_t page = (uint64_t)vm_kernel_page_size;
    uint64_t used = ((uint64_t)statistics.active_count + (uint64_t)statistics.wire_count +
                     (uint64_t)statistics.compressor_page_count) * page;
    return (double)used / 1073741824.0;
}

// 公开的 if_data 计数器，避开私有 if_msghdr2。
static BOOL QFNetworkTotals(uint64_t *bytesIn, uint64_t *bytesOut) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || !list) return NO;
    uint64_t totalIn = 0;
    uint64_t totalOut = 0;
    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_LINK) continue;
        if (entry->ifa_flags & IFF_LOOPBACK) continue;
        struct if_data *data = (struct if_data *)entry->ifa_data;
        if (!data) continue;
        totalIn += data->ifi_ibytes;
        totalOut += data->ifi_obytes;
    }
    freeifaddrs(list);
    *bytesIn = totalIn;
    *bytesOut = totalOut;
    return YES;
}

@implementation QFMetrics {
    NSTimeInterval _previousTime;
    uint64_t _previousIn;
    uint64_t _previousOut;
}

+ (instancetype)shared {
    static QFMetrics *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [QFMetrics new];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        UIDevice *device = [UIDevice currentDevice];
        device.batteryMonitoringEnabled = YES;
        [self sample];
    }
    return self;
}

- (void)sample {
    _cpuPercent = QFCPUSample();
    _memoryGB = QFMemorySample();

    uint64_t bytesIn = 0;
    uint64_t bytesOut = 0;
    if (QFNetworkTotals(&bytesIn, &bytesOut)) {
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (_previousTime > 0 && now - _previousTime > 0.2) {
            double elapsed = now - _previousTime;
            _downloadRate = bytesIn >= _previousIn ? (bytesIn - _previousIn) / elapsed : 0.0;
            _uploadRate = bytesOut >= _previousOut ? (bytesOut - _previousOut) / elapsed : 0.0;
        }
        _previousIn = bytesIn;
        _previousOut = bytesOut;
        _previousTime = now;
    }

    float level = [UIDevice currentDevice].batteryLevel;
    _batteryPercent = level >= 0 ? (NSInteger)lroundf(level * 100.0f) : -1;
}

+ (NSString *)rateText:(double)bytesPerSecond {
    if (bytesPerSecond < 1000.0) return [NSString stringWithFormat:@"%.0fB/s", bytesPerSecond];
    if (bytesPerSecond < 1000000.0) return [NSString stringWithFormat:@"%.0fK/s", bytesPerSecond / 1000.0];
    if (bytesPerSecond < 1000000000.0) return [NSString stringWithFormat:@"%.1fM/s", bytesPerSecond / 1000000.0];
    return [NSString stringWithFormat:@"%.2fG/s", bytesPerSecond / 1000000000.0];
}

+ (NSString *)shortRateText:(double)bytesPerSecond {
    if (bytesPerSecond < 1000.0) return [NSString stringWithFormat:@"%.0fB", bytesPerSecond];
    if (bytesPerSecond < 1000000.0) return [NSString stringWithFormat:@"%.0fK", bytesPerSecond / 1000.0];
    if (bytesPerSecond < 1000000000.0) return [NSString stringWithFormat:@"%.1fM", bytesPerSecond / 1000000.0];
    return [NSString stringWithFormat:@"%.2fG", bytesPerSecond / 1000000000.0];
}

@end
