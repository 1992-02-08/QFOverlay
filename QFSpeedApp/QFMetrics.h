// QFMetrics —— 性能采样。和 SpringBoard 侧用同一套公开 API，数值口径一致。

#import <Foundation/Foundation.h>

@interface QFMetrics : NSObject

@property (nonatomic, readonly) double downloadRate;     // B/s
@property (nonatomic, readonly) double uploadRate;
@property (nonatomic, readonly) double cpuPercent;
@property (nonatomic, readonly) double memoryGB;
@property (nonatomic, readonly) NSInteger batteryPercent;

+ (instancetype)shared;

// 采一轮。第一次调用没有基准，速率会是 0，从第二次开始才准。
- (void)sample;

+ (NSString *)rateText:(double)bytesPerSecond;
+ (NSString *)shortRateText:(double)bytesPerSecond;

@end
