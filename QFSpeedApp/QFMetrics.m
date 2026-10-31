#import "QFMetrics.h"

#import <UIKit/UIKit.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/processor_info.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>

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

// IOKit 电池传感器：读取电压/电流/温度（越狱设备 AppleSmartBattery）
static BOOL QFBatterySensor(double *voltage, double *amperage, double *temperature) {
    if (voltage) *voltage = 0.0;
    if (amperage) *amperage = 0.0;
    if (temperature) *temperature = 0.0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSmartBattery"));
    if (!service) return NO;

    CFNumberRef cfVoltage = IORegistryEntryCreateCFProperty(service, CFSTR("Voltage"), kCFAllocatorDefault, 0);
    CFNumberRef cfAmperage = IORegistryEntryCreateCFProperty(service, CFSTR("Amperage"), kCFAllocatorDefault, 0);
    CFNumberRef cfTemp = IORegistryEntryCreateCFProperty(service, CFSTR("Temperature"), kCFAllocatorDefault, 0);

    if (cfVoltage && voltage) {
        int mv = 0;
        CFNumberGetValue(cfVoltage, kCFNumberIntType, &mv);
        *voltage = mv / 1000.0; // mV -> V
        CFRelease(cfVoltage);
    }
    if (cfAmperage && amperage) {
        int ma = 0;
        CFNumberGetValue(cfAmperage, kCFNumberIntType, &ma);
        *amperage = (double)ma; // mA
        CFRelease(cfAmperage);
    }
    if (cfTemp && temperature) {
        int deciC = 0;
        CFNumberGetValue(cfTemp, kCFNumberIntType, &deciC);
        *temperature = deciC / 100.0; // AppleSmartBattery Temperature 单位 0.01°C -> °C
        CFRelease(cfTemp);
    }

    IOObjectRelease(service);
    return YES;
}

// FPS 采样：CADisplayLink 回调计帧
@interface QFFPSCounter : NSObject
@property (nonatomic, readonly) double currentFPS;
- (void)start;
- (void)stop;
@end

@implementation QFFPSCounter {
    CADisplayLink *_link;
    NSInteger _frameCount;
    CFTimeInterval _lastTime;
}

- (void)start {
    if (_link) return;
    _frameCount = 0;
    _lastTime = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [_link invalidate];
    _link = nil;
}

- (void)tick:(CADisplayLink *)link {
    _frameCount++;
    CFTimeInterval elapsed = link.timestamp - _lastTime;
    if (elapsed >= 0.5) {
        _currentFPS = _frameCount / elapsed;
        _frameCount = 0;
        _lastTime = link.timestamp;
    }
}

@end

@implementation QFMetrics {
    NSTimeInterval _previousTime;
    uint64_t _previousIn;
    uint64_t _previousOut;
    QFFPSCounter *_fpsCounter;
    double _fps;
    double _voltage;
    double _amperage;
    double _wattage;
    double _temperature;
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
        _fpsCounter = [QFFPSCounter new];
        [_fpsCounter start];
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

    // IPA 扩展指标：FPS + 电池传感器
    _fps = _fpsCounter.currentFPS;
    double v = 0, a = 0, t = 0;
    if (QFBatterySensor(&v, &a, &t)) {
        _voltage = v;
        _amperage = a;
        _temperature = t;
        _wattage = v * a / 1000.0; // V * mA / 1000 = W
    }
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
