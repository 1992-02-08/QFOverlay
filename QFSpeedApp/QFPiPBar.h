// QFPiPBar —— 把浮条塞进系统「画中画」层，从而做到跨 App 常驻。
//
// 为什么只能这样：iOS 里 App 自己的 UIWindow 一旦退到后台，所属 scene 就不再被合成，
// 窗口立刻消失。没有任何保活手段能改变这一点（音频后台也不行，进程活着的窗口没人画）。
// 系统唯一允许「别的前台 App 之上还有一块属于你的画面」的合法通道就是画中画 ——
// PiP 窗口由 SpringBoard 合成，App 退到后台、回桌面、切别的 App 都照常显示。
//
// 代价（必须让用户知道）：
//   · 画面是「视频」，不能做真正的透明浮条，只能画成深色卡片；
//   · PiP 窗口大小/位置由系统管，内容不可点、不可拖动（拖动整个窗口可以）；
//   · 锁屏后系统会收起 PiP，锁屏显示做不到（那是越狱插件的事）。
//
// 实现：AVSampleBufferDisplayLayer 自绘帧（每秒重画一次文字），
// AVPictureInPictureController 用 sampleBuffer 源推到系统层。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface QFPiPBar : NSObject

@property (class, nonatomic, readonly) QFPiPBar *shared;

@property (nonatomic, readonly) BOOL available;   // 设备/系统支持画中画
@property (nonatomic, readonly) BOOL running;     // 当前是否已在画中画中

// 必须在 App 有个可用 scene 之后调用，内部把渲染层挂到该 scene 的视图上。
- (BOOL)prepareWithScene:(UIWindowScene *)scene;

- (void)start;
- (void)stop;
- (void)updateText:(NSString *)text;

// 最近一次失败原因，界面直接显示，省得来回猜。
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

@end

NS_ASSUME_NONNULL_END
