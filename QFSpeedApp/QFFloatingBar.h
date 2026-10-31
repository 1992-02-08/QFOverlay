// QFFloatingBar —— 本 App 自己的浮条。
//
// 只在 App 自己的进程里画（没有越狱时这是唯一能显示的东西）；设备装了
// com.wacljcr.qfoverlay 时由 SpringBoard 那份画，这个就自动让位不显示。

#import <UIKit/UIKit.h>

@interface QFFloatingBar : NSObject

@property (class, nonatomic, readonly) QFFloatingBar *shared;

@property (nonatomic, readonly, getter=isVisible) BOOL visible;
@property (nonatomic) BOOL locked;      // 锁定后拖不动
@property (nonatomic) BOOL compact;     // 只显示上下行

- (void)show;
- (void)hide;
- (void)toggle;
- (void)updateText:(NSString *)text;
- (void)resetPosition;

@end
