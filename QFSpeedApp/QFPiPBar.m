#import "QFPiPBar.h"
#import "../QFShared.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreVideo/CoreVideo.h>

// 画布尺寸决定 PiP 窗口的宽高比。2.5:1 比较接近横条，又不至于把字压得太小。
static const CGFloat QFCanvasWidth = 480.0;
static const CGFloat QFCanvasHeight = 192.0;

@interface QFPiPBar () <AVPictureInPictureControllerDelegate,
                        AVPictureInPictureSampleBufferPlaybackDelegate>
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) UIView *anchorView;
@property (nonatomic, strong) NSTimer *feedTimer;
@property (nonatomic, strong) NSString *text;
@property (nonatomic) BOOL prepared;
@property (nonatomic) BOOL running;
@property (nonatomic, readwrite) BOOL available;
@property (nonatomic, readwrite, copy, nullable) NSString *lastError;
@property (nonatomic) NSInteger frameIndex;
@property (nonatomic) BOOL pendingStart;
@property (nonatomic) NSInteger startRetries;
@property (nonatomic, strong) AVAudioPlayer *keepAlivePlayer;
@end

@implementation QFPiPBar {
    CMTimebaseRef _timebase;
    BOOL _stopping;
}

+ (instancetype)shared {
    static QFPiPBar *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [QFPiPBar new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _text = @"↓0B ↑0B";
        if (@available(iOS 15.0, *)) {
            _available = AVPictureInPictureController.isPictureInPictureSupported;
        } else {
            _available = NO;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_feedTimer invalidate];
    [_keepAlivePlayer stop];
    if (_timebase) CFRelease(_timebase);
}

#pragma mark - 准备

- (BOOL)prepareWithScene:(UIWindowScene *)scene {
    if (!self.available) {
        self.lastError = @"这台设备不支持画中画";
        return NO;
    }
    if (self.prepared) return YES;
    if (@available(iOS 15.0, *)) {
        UIWindow *keyWindow = nil;
        for (UIWindow *window in scene.windows) {
            if (window.isKeyWindow) { keyWindow = window; break; }
            if (!keyWindow) keyWindow = window;
        }
        UIView *host = keyWindow.rootViewController.view ?: keyWindow;
        if (!host) {
            self.lastError = @"找不到可挂载的视图";
            return NO;
        }

        // 渲染层必须真的挂在视图层级里（hidden / alpha 0 会让 isPictureInPicturePossible 变 false），
        // 所以塞一个 2x2 的透明锚点，用户看不见，但系统认为它在渲染。
        self.anchorView = [[UIView alloc] initWithFrame:CGRectMake(2.0, 2.0, 2.0, 2.0)];
        self.anchorView.backgroundColor = UIColor.blackColor;
        self.anchorView.userInteractionEnabled = NO;
        [host addSubview:self.anchorView];

        self.displayLayer = [AVSampleBufferDisplayLayer layer];
        self.displayLayer.frame = self.anchorView.bounds;
        self.displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        [self.anchorView.layer addSublayer:self.displayLayer];

        CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &_timebase);
        CMTimebaseSetTime(_timebase, kCMTimeZero);
        CMTimebaseSetRate(_timebase, 1.0);
        self.displayLayer.controlTimebase = _timebase;

        AVPictureInPictureControllerContentSource *source =
            [[AVPictureInPictureControllerContentSource alloc]
                initWithSampleBufferDisplayLayer:self.displayLayer
                               playbackDelegate:self];
        self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:source];
        self.pipController.delegate = self;
        // 用户在别的 App 里按 Home 时自动浮起来，不必先回本 App。
        self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        // 注意：这里不设 requiresLinearPlayback。配合无限时长（直播语义）时它是多余的，
        // 而 first-start 失败（PGPegasusErrorDomain -1003）往往就出在这种多余配置上。

        // 提前开始喂帧：让渲染层在用户点按钮之前就已经进入 readyForDisplay。
        // 层没真正开始渲染时调 start，系统会直接甩 -1003。
        [self startFeedTimer];
        self.prepared = YES;
        QFLogMessage(@"画中画已准备");
        return YES;
    }
    self.lastError = @"系统版本过低（需要 iOS 15 以上）";
    return NO;
}

#pragma mark - 起停

- (void)start {
    if (!self.prepared) {
        self.lastError = @"画中画尚未准备好";
        return;
    }
    if (self.running) return;
    if (@available(iOS 15.0, *)) {
        self.startRetries = 0;
        self.lastError = nil;
        [self activateAudioSession];
        [self startKeepAlive];
        [self startFeedTimer];
        [self renderFrame];
        self.pendingStart = YES;
        [self attemptStart:0];
    }
}

- (void)activateAudioSession {
    [self activateAudioSessionAllowMixing:YES];
}

- (void)activateAudioSessionAllowMixing:(BOOL)allowMixing {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    AVAudioSessionCategoryOptions options = allowMixing ? AVAudioSessionCategoryOptionMixWithOthers : 0;
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeMoviePlayback
                 options:options
                   error:&error];
    if (![session setActive:YES error:&error]) {
        QFLogFormat(@"音频会话激活失败(%@) %@", allowMixing ? @"mix" : @"exclusive", error.localizedDescription);
    }
}

// 循环播放一段本地生成的静音 PCM。
// PiP 要求 App 处于「正在播放」状态；只 setActive 不放东西，部分系统版本里会被判定
// 没有可继续的后台内容，进而拒绝启动 PiP。音量设 0，用户听不到任何声音。
- (void)startKeepAlive {
    if (self.keepAlivePlayer) {
        [self.keepAlivePlayer play];
        return;
    }
    NSData *wav = [self silentWavData];
    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:wav error:&error];
    if (!player) {
        QFLogFormat(@"静音保活初始化失败 %@", error.localizedDescription);
        return;
    }
    player.numberOfLoops = -1;
    player.volume = 0.0;
    [player prepareToPlay];
    [player play];
    self.keepAlivePlayer = player;
}

- (void)stopKeepAlive {
    [self.keepAlivePlayer stop];
    self.keepAlivePlayer = nil;
}

- (NSData *)silentWavData {
    const uint32_t sampleRate = 8000;
    const uint32_t frames = sampleRate / 2;   // 0.5 秒
    const uint16_t channels = 1;
    const uint16_t bitsPerSample = 16;
    const uint32_t dataSize = frames * channels * (bitsPerSample / 8);
    const uint32_t byteRate = sampleRate * channels * (bitsPerSample / 8);
    const uint16_t blockAlign = channels * (bitsPerSample / 8);

    NSMutableData *data = [NSMutableData dataWithCapacity:44 + dataSize];
    void (^put)(NSString *, NSUInteger) = ^(NSString *tag, NSUInteger value) {
        [data appendBytes:tag.UTF8String length:4];
        uint32_t little = (uint32_t)value;
        [data appendBytes:&little length:4];
    };
    void (^put16)(NSString *, uint16_t) = ^(NSString *tag, uint16_t value) {
        [data appendBytes:tag.UTF8String length:4];
        [data appendBytes:&value length:2];
    };
    put(@"RIFF", 36 + dataSize);
    [data appendBytes:"WAVE" length:4];
    put16(@"fmt ", 16);
    uint16_t pcm = 1;
    [data appendBytes:&pcm length:2];
    uint16_t channelCount = channels;
    [data appendBytes:&channelCount length:2];
    uint32_t rate = sampleRate;
    [data appendBytes:&rate length:4];
    uint32_t rateBytes = byteRate;
    [data appendBytes:&rateBytes length:4];
    uint16_t align = blockAlign;
    [data appendBytes:&align length:2];
    uint16_t bits = bitsPerSample;
    [data appendBytes:&bits length:2];
    put(@"data", dataSize);
    [data appendData:[NSMutableData dataWithLength:dataSize]];   // 全 0 = 静音
    return data;
}

- (void)attemptStart:(NSInteger)attempt {
    if (!self.pendingStart) return;
    if (@available(iOS 15.0, *)) {
        if (self.pipController.isPictureInPictureActive) return;
        // 除了 possible，还要等渲染层真的进入 readyForDisplay。
        // 层没开始渲染就调 start，系统会直接甩 PGPegasusErrorDomain -1003。
        // isReadyForDisplay 是 iOS 17.4 才有的属性，iOS 16 上直接调会 unrecognized selector。
        // 16.x 用 status == Rendering 判断，语义等价且从 iOS 6 就有。
        BOOL ready = YES;
        if (@available(iOS 17.4, *)) {
            ready = self.displayLayer.isReadyForDisplay;
        } else if (@available(iOS 15.0, *)) {
            ready = (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusRendering);
        }
        BOOL possible = self.pipController.isPictureInPicturePossible;
        // readyForDisplay 是软条件：连续几轮还不 ready 也硬试一次，
        // 免得 KVO 状态没刷新把路堵死。
        if (possible && (ready || attempt >= 2)) {
            QFLogFormat(@"启动画中画（第 %ld 次尝试，layer ready=%d）", (long)(attempt + 1), (int)ready);
            [self.pipController startPictureInPicture];
            return;
        }
        if (attempt >= 12) {
            self.lastError = @"系统未允许画中画，按 Home 键再试";
            QFLogFormat(@"放弃启动：possible=%d ready=%d", (int)possible, (int)ready);
            return;
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf attemptStart:attempt + 1]; });
    }
}

- (void)stop {
    self.pendingStart = NO;
    self.startRetries = 0;
    if (@available(iOS 15.0, *)) {
        _stopping = YES;
        if (self.pipController.isPictureInPictureActive) {
            [self.pipController stopPictureInPicture];
        }
        _stopping = NO;
    }
    [self stopFeedTimer];
    [self stopKeepAlive];
    self.running = NO;
}

- (void)startFeedTimer {
    [self stopFeedTimer];
    __weak typeof(self) weakSelf = self;
    self.feedTimer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf renderFrame];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.feedTimer forMode:NSRunLoopCommonModes];
}

- (void)stopFeedTimer {
    [self.feedTimer invalidate];
    self.feedTimer = nil;
}

- (void)updateText:(NSString *)text {
    if (text.length == 0 || [text isEqualToString:self.text]) return;
    self.text = text;
    [self renderFrame];
}

#pragma mark - 裁帧

- (void)renderFrame {
    if (!self.displayLayer) return;
    if (@available(iOS 15.0, *)) {
        if (self.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
            [self.displayLayer flush];
        }
        // 队列没消化完就别再塞，否则帧会越积越多、PiP 画面追不上真实时间。
        if (!self.displayLayer.isReadyForMoreMediaData) return;
    }
    CMSampleBufferRef sample = [self newSampleBuffer];
    if (!sample) return;
    if (@available(iOS 15.0, *)) {
        [self.displayLayer enqueueSampleBuffer:sample];
    }
    CFRelease(sample);
}

- (CMSampleBufferRef)newSampleBuffer {
    size_t width = (size_t)QFCanvasWidth;
    size_t height = (size_t)QFCanvasHeight;

    NSDictionary *attributes = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };
    CVPixelBufferRef pixelBuffer = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &pixelBuffer) != kCVReturnSuccess) {
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *base = CVPixelBufferGetBaseAddress(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(base, width, height, 8, bytesPerRow, colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);

    if (!context) {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }

    // UIGraphicsImageRenderer 画好再贴到像素缓冲：文字排版走 UIKit，省得自己算基线。
    UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
    format.opaque = YES;
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height) format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [self drawInContext:ctx.CGContext size:CGSizeMake(width, height)];
    }];

    // CGBitmapContext 原点在左下，UIKit 画出来的是左上原点，贴图前要翻一次。
    CGContextTranslateCTM(context, 0, height);
    CGContextScaleCTM(context, 1, -1);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    CMVideoFormatDescriptionRef description = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                     &description) != noErr) {
        CVPixelBufferRelease(pixelBuffer);
        return NULL;
    }
    CMTime pts = _timebase ? CMTimebaseGetTime(_timebase) : CMTimeMake(++self.frameIndex * 1000, 1000);
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), pts, kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer,
                                                              description, &timing, &sample);
    CFRelease(description);
    CVPixelBufferRelease(pixelBuffer);
    if (status != noErr) return NULL;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef attachment =
            (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    }
    return sample;
}

- (void)drawInContext:(CGContextRef)context size:(CGSize)size {
    // 背景不能透明（PiP 底色固定），做深色卡片最接近浮条观感。
    CGContextSetRGBFillColor(context, 0.055, 0.055, 0.070, 1.0);
    CGContextFillRect(context, CGRectMake(0, 0, size.width, size.height));

    NSString *text = self.text ?: @"↓0B ↑0B";
    NSArray<NSString *> *parts = [text componentsSeparatedByString:@"  "];
    NSString *primary = parts.firstObject ?: text;
    NSString *secondary = parts.count > 1 ? [parts componentsJoinedByString:@"  "] : @"";
    if (parts.count > 1) {
        NSMutableArray *rest = [parts mutableCopy];
        [rest removeObjectAtIndex:0];
        secondary = [rest componentsJoinedByString:@"   "];
    }

    NSMutableParagraphStyle *centered = [[NSMutableParagraphStyle alloc] init];
    centered.alignment = NSTextAlignmentCenter;
    NSDictionary *primaryAttributes = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:44.0 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.97],
        NSParagraphStyleAttributeName: centered,
    };
    CGRect primaryRect = CGRectMake(16.0, secondary.length > 0 ? 40.0 : 64.0,
                                    size.width - 32.0, 58.0);
    [primary drawInRect:primaryRect withAttributes:primaryAttributes];

    if (secondary.length > 0) {
        NSDictionary *secondaryAttributes = @{
            NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:26.0 weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.62 green:0.66 blue:0.74 alpha:1.0],
            NSParagraphStyleAttributeName: centered,
        };
        [secondary drawInRect:CGRectMake(16.0, 108.0, size.width - 32.0, 36.0)
               withAttributes:secondaryAttributes];
    }
}

#pragma mark - 前后台

- (void)handleBackground {
    if (!self.prepared || !self.pendingStart) return;
    [self activateAudioSession];
    [self startKeepAlive];
    [self startFeedTimer];
    [self attemptStart:0];
}

- (void)handleForeground {
    // 回前台时 PiP 会自己收回 inline，这里只保证数据仍在刷新。
    if (self.prepared) [self startFeedTimer];
}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)controller {
    self.running = YES;
    self.startRetries = 0;
    self.lastError = nil;
    [self startFeedTimer];
    [self startKeepAlive];
    QFLogMessage(@"画中画已启动");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    self.running = NO;
    // 两种"停止"要分开：用户点窗口上的关闭键（App 在后台，意图是真的关），
    // 和用户回到本 App 被系统自动收回（不能当成关闭，否则状态就假了）。
    BOOL userClosed = !_stopping && UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    if (userClosed) {
        self.pendingStart = NO;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"QFPiPDidStop" object:nil];
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    failedToStartPictureInPictureWithError:(NSError *)error {
    self.running = NO;
    QFLogFormat(@"画中画启动失败 domain=%@ code=%ld desc=%@",
                error.domain, (long)error.code, error.localizedDescription);

    // AVSampleBufferDisplayLayer 源有个已知毛病：首次 start 会失败
    // （PGPegasusErrorDomain -1003），紧接着再调一次通常就成了。
    // 这是系统侧行为，不是我们配置错，所以自动重试，别把临时失败甩给用户看。
    if (self.pendingStart && self.startRetries < 3) {
        self.startRetries += 1;
        QFLogFormat(@"画中画启动失败，第 %ld 次自动重试", (long)self.startRetries);
        // 第一次用「可混音」的会话（不打断用户正在放的音乐）；重试时改成独占 playback ——
        // 部分系统版本里可混音会话会让 PiP 判定「没有主音频会话」而拒绝启动。
        [self activateAudioSessionAllowMixing:NO];
        [self startKeepAlive];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf attemptStart:0]; });
        return;
    }
    self.lastError = error.localizedDescription ?: @"画中画启动失败";
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    completionHandler(YES);
}

#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
                        setPlaying:(BOOL)playing API_AVAILABLE(ios(15.0)) {
    // 用户点暂停不真的停：这是状态条不是视频，停了就成一张死图。
    (void)controller;
    (void)playing;
}

- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller
    API_AVAILABLE(ios(15.0)) {
    (void)controller;
    // 无限时长 = 直播语义，系统不显示进度条。
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}

- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller
    API_AVAILABLE(ios(15.0)) {
    (void)controller;
    return NO;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
             didTransitionToRenderSize:(CMVideoDimensions)newRenderSize API_AVAILABLE(ios(15.0)) {
    (void)controller;
    (void)newRenderSize;
}

- (void)pictureInPictureController:(AVPictureInPictureController *)controller
                    skipByInterval:(CMTime)skipInterval
                 completionHandler:(void (^)(void))completionHandler API_AVAILABLE(ios(15.0)) {
    (void)controller;
    (void)skipInterval;
    if (completionHandler) completionHandler();
}

@end
