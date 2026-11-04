#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <dns_sd.h>
#include "raop.h"
#include "logger.h"

@interface MirrorController : UIViewController <UIGestureRecognizerDelegate> {
@public
    raop_t *_server;
    dnssd_t *_discovery;
    CMVideoFormatDescriptionRef _format;
}
@property AVSampleBufferDisplayLayer *display;
@property CALayer *videoViewport;
@property UIButton *viewfinderButton;
@property UIButton *resetFrameButton;
@property BOOL viewfinder;
@property CGFloat previewZoom;
@property CGPoint previewPan;
@property CGSize encodedSize;
@property BOOL hasSourceGeometry;
@property UIStackView *instructions;
@property UILabel *status;
@property UILabel *pinLabel;
@property UIButton *overlay;
@property UIButton *rotateButton;
@property BOOL stopping;
@property BOOL wantsReceiver;
@property (atomic) BOOL acceptsFrames;
@property (atomic) NSUInteger generation;
@property NSInteger quarterTurns;
@property CGSize streamSize;
@property dispatch_queue_t videoQueue;
@property NSMutableArray *dnsSources;
@property NSData *sps;
@property NSData *pps;
@property BOOL showingVideo;
@property BOOL starting;
- (void)consumeVideo:(NSData *)data;
- (void)followStreamOrientation;
- (void)restoreFraming;
- (void)startReceiver;
- (void)stopReceiver;
@end

static MirrorController *controller(void *cls) { return (__bridge MirrorController *)cls; }
static void noop(void *cls) {}
static void resetVideo(void *cls, reset_type_t type) {
    MirrorController *c = controller(cls);
    NSUInteger generation = c.generation;
    dispatch_async(c.videoQueue, ^{
        if (generation != c.generation || !c.acceptsFrames) return;
        [c.display flushAndRemoveImage];
        c.sps = nil; c.pps = nil;
        if (c->_format) { CFRelease(c->_format); c->_format = NULL; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != c.generation) return;
            c.showingVideo = NO; c.instructions.hidden = NO; c.overlay.hidden = YES; c.rotateButton.hidden = YES; c.viewfinderButton.hidden = YES; c.resetFrameButton.hidden = YES; c.hasSourceGeometry = NO; c.encodedSize = CGSizeZero;
            c.quarterTurns = 0; c.streamSize = CGSizeZero;
            [c.view setNeedsLayout];
            c.status.text = @"Ready to mirror";
        });
    });
}
static void video(void *cls, raop_ntp_t *ntp, video_decode_struct *frame) {
    if (frame->is_h265 || frame->data_len <= 0 || frame->data_len > 16*1024*1024) return;
    MirrorController *c = controller(cls);
    if (!c.acceptsFrames) return;
    NSUInteger generation = c.generation;
    NSData *copy = [NSData dataWithBytes:frame->data length:frame->data_len];
    dispatch_async(c.videoQueue, ^{
        if (generation == c.generation && c.acceptsFrames) [c consumeVideo:copy];
    });
}
static int codec(void *cls, video_codec_t codec, unsigned short a, unsigned short b, unsigned short x, unsigned short y, unsigned short w, unsigned short h) {
    if (codec != VIDEO_CODEC_H264) return -1;
    MirrorController *c = controller(cls);
    NSUInteger generation = c.generation;
    if (a && b) dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != c.generation || !c.acceptsFrames) return;
        CGSize size = CGSizeMake(a, b);
        c.hasSourceGeometry = YES;
        if (!CGSizeEqualToSize(size, c.streamSize)) {
            NSLog(@"AirPlay source geometry %u x %u, viewport %u x %u", a, b, w, h);
            c.streamSize = size; c.quarterTurns = 0;
            [c followStreamOrientation]; [c.view setNeedsLayout];
        }
    });
    return 0;
}
static void audio(void *cls, raop_ntp_t *ntp, audio_decode_struct *data) {}
static double volume(void *cls) { return 0.0; }
static void setVolume(void *cls, float value) {}
static void pin(void *cls, char *value) {
    NSString *code = [NSString stringWithUTF8String:value];
    dispatch_async(dispatch_get_main_queue(), ^{
        controller(cls).pinLabel.text = [@"AirPlay code  " stringByAppendingString:code];
        controller(cls).pinLabel.hidden = NO;
    });
}
static void client(void *cls, char *id, char *model, char *name, bool *admit) { *admit = true; }
static const char *password(void *cls, int *length) { *length = 0; return NULL; }
static void registerClient(void *cls, const char *id, const char *key, const char *name) {}
static bool checkClient(void *cls, const char *key) { return false; }
static void logMessage(void *cls, int level, const char *message) { NSLog(@"AirPlay %s", message); }

@implementation MirrorController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.videoQueue = dispatch_queue_create("mirror.video", DISPATCH_QUEUE_SERIAL);
    self.dnsSources = [NSMutableArray array];
    self.display = [AVSampleBufferDisplayLayer layer];
    self.display.videoGravity = AVLayerVideoGravityResizeAspect;
    self.previewZoom = 1;
    self.videoViewport = [CALayer layer];
    self.videoViewport.masksToBounds = YES;
    [self.videoViewport addSublayer:self.display];
    [self.view.layer addSublayer:self.videoViewport];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"rectangle.on.rectangle"]];
    icon.tintColor = [UIColor colorWithWhite:0.85 alpha:1];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [icon.heightAnchor constraintEqualToConstant:52].active = YES;
    UILabel *title = [self label:@"Mirror" size:36 weight:UIFontWeightSemibold];
    self.status = [self label:@"Starting receiver…" size:18 weight:UIFontWeightMedium];
    self.status.textColor = [UIColor colorWithRed:0.55 green:0.87 blue:0.72 alpha:1];
    UILabel *steps = [self label:@"On your iPhone, open Control Center.\nTap Screen Mirroring → iPad Mirror.\nThen open Camera." size:20 weight:UIFontWeightRegular];
    steps.textColor = UIColor.lightGrayColor;
    self.pinLabel = [self label:@"" size:28 weight:UIFontWeightSemibold];
    self.pinLabel.hidden = YES;
    UILabel *foot = [self label:@"Keep both devices on the same Wi-Fi.\nKeep this app open. Video preview only; no audio playback on this iPad." size:14 weight:UIFontWeightRegular];
    foot.textColor = UIColor.grayColor;
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"Restart receiver" forState:UIControlStateNormal];
    [retry addTarget:self action:@selector(restart) forControlEvents:UIControlEventTouchUpInside];
    retry.tintColor = UIColor.lightGrayColor;
    self.instructions = [[UIStackView alloc] initWithArrangedSubviews:@[icon,title,self.status,steps,self.pinLabel,foot,retry]];
    self.instructions.axis = UILayoutConstraintAxisVertical;
    self.instructions.spacing = 24;
    self.instructions.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.instructions];
    [NSLayoutConstraint activateConstraints:@[
        [self.instructions.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.instructions.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.instructions.widthAnchor constraintLessThanOrEqualToConstant:520],
        [self.instructions.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.instructions.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24]
    ]];
    self.overlay = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.overlay setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    self.overlay.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.overlay.frame = CGRectMake(24, 30, 44, 44);
    self.overlay.hidden = YES;
    self.overlay.accessibilityLabel = @"Disconnect mirroring";
    [self.overlay addTarget:self action:@selector(restart) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.overlay];
    self.rotateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.rotateButton setImage:[UIImage systemImageNamed:@"rotate.left"] forState:UIControlStateNormal];
    self.rotateButton.tintColor = self.overlay.tintColor;
    self.rotateButton.hidden = YES;
    self.rotateButton.accessibilityLabel = @"Rotate preview 90 degrees";
    [self.rotateButton addTarget:self action:@selector(rotatePreview) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.rotateButton];
    self.viewfinderButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.viewfinderButton.tintColor = self.overlay.tintColor;
    self.viewfinderButton.hidden = YES;
    [self.viewfinderButton addTarget:self action:@selector(toggleViewfinder) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.viewfinderButton];
    self.resetFrameButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.resetFrameButton.tintColor = self.overlay.tintColor;
    self.resetFrameButton.hidden = YES;
    [self.resetFrameButton setImage:[UIImage systemImageNamed:@"arrow.counterclockwise"] forState:UIControlStateNormal];
    self.resetFrameButton.accessibilityLabel = @"Reset viewfinder framing";
    [self.resetFrameButton addTarget:self action:@selector(resetFraming) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.resetFrameButton];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinchPreview:)];
    pinch.delegate = self; [self.view addGestureRecognizer:pinch];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panPreview:)];
    pan.delegate = self; [self.view addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)];
    tap.delegate = self;
    [self.view addGestureRecognizer:tap];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(foreground) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self startReceiver];
}
- (UILabel *)label:(NSString *)text size:(CGFloat)size weight:(UIFontWeight)weight {
    UILabel *label = [UILabel new]; label.text = text; label.textColor = UIColor.whiteColor;
    label.textAlignment = NSTextAlignmentCenter; label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:size weight:weight]; return label;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    BOOL sideways = self.quarterTurns % 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGSize raster = self.encodedSize;
    if (!self.viewfinder || raster.width <= 0 || raster.height <= 0) {
        self.videoViewport.frame = self.view.bounds;
        self.display.bounds = CGRectMake(0, 0, sideways ? size.height : size.width, sideways ? size.width : size.height);
        self.display.position = CGPointMake(size.width / 2, size.height / 2);
        self.display.affineTransform = CGAffineTransformMakeRotation(self.quarterTurns * M_PI_2);
    } else {
        // Photo-mode preset: keep the 4:3 preview, excluding the surrounding phone UI.
        // Pinch/drag can adjust this preset for other Camera modes and phone layouts.
        CGRect crop;
        if (raster.height > raster.width) {
            CGFloat height = MIN(raster.width * 4.0 / 3.0, raster.height);
            CGFloat top = MIN(raster.height * 0.145, raster.height - height);
            crop = CGRectMake(0, top, raster.width, height);
        } else {
            CGFloat width = MIN(raster.height * 4.0 / 3.0, raster.width);
            crop = CGRectMake((raster.width - width) / 2, 0, width, raster.height);
        }
        CGSize visible = sideways ? CGSizeMake(crop.size.height, crop.size.width) : crop.size;
        CGFloat fit = MIN(size.width / visible.width, size.height / visible.height);
        CGSize viewport = CGSizeMake(visible.width * fit, visible.height * fit);
        self.videoViewport.frame = CGRectMake((size.width - viewport.width) / 2, (size.height - viewport.height) / 2, viewport.width, viewport.height);
        CGFloat scale = fit * self.previewZoom;
        CGAffineTransform transform = CGAffineTransformMakeRotation(self.quarterTurns * M_PI_2);
        transform = CGAffineTransformScale(transform, scale, scale);
        CGPoint delta = CGPointApplyAffineTransform(CGPointMake(CGRectGetMidX(crop) - raster.width / 2, CGRectGetMidY(crop) - raster.height / 2), transform);
        self.display.bounds = CGRectMake(0, 0, raster.width, raster.height);
        self.display.affineTransform = transform;
        self.display.position = CGPointMake(viewport.width / 2 - delta.x + self.previewPan.x * viewport.width, viewport.height / 2 - delta.y + self.previewPan.y * viewport.height);
    }
    [CATransaction commit];
    CGFloat top = MAX(self.view.safeAreaInsets.top, 12);
    CGFloat right = CGRectGetMaxX(self.view.bounds) - MAX(self.view.safeAreaInsets.right, 16);
    self.overlay.frame = CGRectMake(right - 48, top, 48, 48);
    self.rotateButton.frame = CGRectMake(right - 108, top, 48, 48);
    self.viewfinderButton.frame = CGRectMake(right - 168, top, 48, 48);
    self.resetFrameButton.frame = CGRectMake(right - 228, top, 48, 48);
    [self.viewfinderButton setImage:[UIImage systemImageNamed:self.viewfinder ? @"rectangle.on.rectangle" : @"viewfinder"] forState:UIControlStateNormal];
    self.viewfinderButton.accessibilityLabel = self.viewfinder ? @"Show full phone screen" : @"Show camera viewfinder";
    [self.rotateButton setImage:[UIImage systemImageNamed:@"rotate.left"] forState:UIControlStateNormal];
    self.rotateButton.accessibilityLabel = @"Rotate preview counterclockwise 90 degrees";
    self.rotateButton.accessibilityValue = [NSString stringWithFormat:@"%ld degrees", (long)self.quarterTurns * 90];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    for (UIView *view = touch.view; view; view = view.superview) if ([view isKindOfClass:UIControl.class]) return NO;
    return YES;
}
- (void)toggleViewfinder {
    self.viewfinder = !self.viewfinder;
    [self restoreFraming];
    self.resetFrameButton.hidden = !self.viewfinder;
    [self.view setNeedsLayout];
}
- (NSString *)framingKey {
    CGSize size = self.encodedSize;
    return [NSString stringWithFormat:@"framing.%@.%ld", size.width > size.height ? @"landscape" : @"portrait", (long)self.quarterTurns];
}
- (void)saveFraming {
    [NSUserDefaults.standardUserDefaults setObject:@{ @"zoom": @(self.previewZoom), @"x": @(self.previewPan.x), @"y": @(self.previewPan.y) } forKey:[self framingKey]];
}
- (void)restoreFraming {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:[self framingKey]];
    self.previewZoom = saved ? MAX(0.6, MIN(3.0, [saved[@"zoom"] doubleValue])) : 1;
    self.previewPan = saved ? CGPointMake([saved[@"x"] doubleValue], [saved[@"y"] doubleValue]) : CGPointZero;
}
- (void)resetFraming {
    self.previewZoom = 1; self.previewPan = CGPointZero;
    [self saveFraming]; [self.view setNeedsLayout];
}
- (void)pinchPreview:(UIPinchGestureRecognizer *)gesture {
    if (!self.showingVideo || !self.viewfinder) return;
    self.previewZoom = MAX(0.6, MIN(3.0, self.previewZoom * gesture.scale));
    gesture.scale = 1; [self.view setNeedsLayout];
    if (gesture.state == UIGestureRecognizerStateEnded) [self saveFraming];
}
- (void)panPreview:(UIPanGestureRecognizer *)gesture {
    if (!self.showingVideo || !self.viewfinder) return;
    CGPoint delta = [gesture translationInView:self.view];
    CGSize size = self.videoViewport.bounds.size;
    self.previewPan = CGPointMake(MAX(-2, MIN(2, self.previewPan.x + delta.x / MAX(size.width, 1))),
                                 MAX(-2, MIN(2, self.previewPan.y + delta.y / MAX(size.height, 1))));
    [gesture setTranslation:CGPointZero inView:self.view]; [self.view setNeedsLayout];
    if (gesture.state == UIGestureRecognizerStateEnded) [self saveFraming];
}
- (void)rotatePreview {
    // Keep advancing counterclockwise so either landscape direction and upside-down work.
    self.quarterTurns = (self.quarterTurns + 3) % 4;
    [self followStreamOrientation]; [self.view setNeedsLayout];
}
- (void)followStreamOrientation {
    // The phone controls its video; the iPad controls its own interface orientation.
    // Never request a window-scene rotation based on the incoming stream.
    [self restoreFraming];
    [self.view setNeedsLayout];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (void)toggleControls {
    if (self.showingVideo) {
        self.overlay.hidden = !self.overlay.hidden;
        self.rotateButton.hidden = self.overlay.hidden && self.quarterTurns == 0;
        self.viewfinderButton.hidden = self.overlay.hidden;
        self.resetFrameButton.hidden = self.overlay.hidden || !self.viewfinder;
    }
}
- (void)background { [self stopReceiver]; UIApplication.sharedApplication.idleTimerDisabled = NO; }
- (void)foreground { [self startReceiver]; }
- (void)restart { [self stopReceiver]; [self startReceiver]; }
- (void)startReceiver {
    self.wantsReceiver = YES;
    if (_server || self.starting || self.stopping) return;
    self.starting = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.status.text = @"Starting receiver…";
    // Stable, locally administered receiver identity, independent of the Wi-Fi MAC.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSData *identity = [defaults dataForKey:@"receiverIdentity"];
    if (identity.length != 6) {
        uint8_t bytes[6]; arc4random_buf(bytes, sizeof bytes); bytes[0] = (bytes[0] | 2) & 0xfe;
        identity = [NSData dataWithBytes:bytes length:6]; [defaults setObject:identity forKey:@"receiverIdentity"];
    }
    const uint8_t *mac = identity.bytes;
    NSString *deviceID = [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",mac[0],mac[1],mac[2],mac[3],mac[4],mac[5]];
    int error = 0;
    _discovery = dnssd_init("iPad Mirror", 11, identity.bytes, 6, 0, &error);
    if (!_discovery || error) { [self fail:@"Could not start local discovery. Tap Restart."]; return; }
    dnssd_set_airplay_features(_discovery, 0, 0); // no remote URL playback
    dnssd_set_airplay_features(_discovery, 4, 0); // no HLS
    dnssd_set_airplay_features(_discovery, 8, 1); // ScreenRotate
    dnssd_set_airplay_features(_discovery, 42, 0); // H.264 for older iPads
    raop_callbacks_t cb = {0}; cb.cls = (__bridge void *)self;
    cb.video_process = video; cb.audio_process = audio;
    cb.video_set_codec_and_size = codec; cb.video_reset = resetVideo;
    cb.video_pause = noop; cb.video_resume = noop;
    cb.conn_init = noop; cb.conn_destroy = noop; cb.conn_feedback = noop;
    cb.video_flush = noop; cb.audio_flush = noop;
    cb.audio_set_client_volume = volume; cb.audio_set_volume = setVolume;
    cb.report_client_request = client; cb.display_pin = pin;
    cb.register_client = registerClient; cb.check_register = checkClient; cb.passwd = password;
    ntp_global_init();
    _server = raop_init(&cb);
    if (!_server) { [self fail:@"Could not create receiver. Tap Restart."]; return; }
    raop_set_log_callback(_server, logMessage, NULL); raop_set_log_level(_server, LOGGER_INFO);
    NSString *keyfile = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"airplay.key"];
    [NSFileManager.defaultManager createDirectoryAtPath:keyfile.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (raop_init2(_server, 0, deviceID.UTF8String, keyfile.UTF8String)) { [self fail:@"Could not initialize AirPlay. Tap Restart."]; return; }
    raop_set_dnssd(_server, _discovery);
    raop_set_plist(_server, "width", 1280); raop_set_plist(_server, "height", 720);
    raop_set_plist(_server, "maxFPS", 30);
    unsigned short tcp[2] = {0}, udp[3] = {0}, port = 0;
    raop_set_tcp_ports(_server, tcp); raop_set_udp_ports(_server, udp);
    if (raop_start_httpd(_server, &port) < 0) { [self fail:@"Could not open receiver. Tap Restart."]; return; }
    raop_set_port(_server, port);
    self.acceptsFrames = YES;
    int a = dnssd_register_raop(_discovery, port), b = dnssd_register_airplay(_discovery, port);
    if (a || b) { [self fail:@"Allow Local Network access in Settings, then tap Restart."]; return; }
    for (int service = 0; service < 2; service++) {
        int fd = dnssd_get_service_fd(_discovery, service);
        if (fd < 0) continue;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{
            if (self->_discovery && dnssd_process_service(self->_discovery, service) != 0) {
                self.status.text = @"Discovery interrupted. Tap Restart receiver.";
            }
        });
        [self.dnsSources addObject:source]; dispatch_resume(source);
    }
    self.starting = NO;
    self.status.text = @"Ready to mirror";
}
- (void)fail:(NSString *)message { [self stopReceiver]; self.status.text = message; }
- (void)stopReceiver {
    // UIKit updates immediately; network shutdown may wait for worker threads.
    self.wantsReceiver = NO;
    self.acceptsFrames = NO;
    self.generation++;
    for (dispatch_source_t source in self.dnsSources) dispatch_source_cancel(source);
    [self.dnsSources removeAllObjects];
    raop_t *server = _server; _server = NULL;
    dnssd_t *discovery = _discovery; _discovery = NULL;
    self.starting = NO; self.showingVideo = NO; self.instructions.hidden = NO;
    self.overlay.hidden = YES; self.rotateButton.hidden = YES; self.viewfinderButton.hidden = YES; self.resetFrameButton.hidden = YES; self.pinLabel.hidden = YES;
    self.hasSourceGeometry = NO; self.encodedSize = CGSizeZero;
    self.status.text = @"Disconnecting…";
    self.quarterTurns = 0; self.streamSize = CGSizeZero;
    [self.view setNeedsLayout];
    dispatch_async(self.videoQueue, ^{
        [self.display flushAndRemoveImage]; self.sps = nil; self.pps = nil;
        if (self->_format) { CFRelease(self->_format); self->_format = NULL; }
    });
    if (!server && !discovery) return;
    self.stopping = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (server) { raop_stop_httpd(server); raop_destroy(server); }
        if (discovery) {
            dnssd_unregister_raop(discovery); dnssd_unregister_airplay(discovery); dnssd_destroy(discovery);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.stopping = NO;
            if (self.wantsReceiver) [self startReceiver];
        });
    });
}
- (void)consumeVideo:(NSData *)data {
    // UxPlay supplies Annex-B H.264. CoreMedia accepts length-prefixed NAL units.
    const uint8_t *bytes = data.bytes; NSUInteger length = data.length;
    NSMutableData *avcc = [NSMutableData data];
    BOOL sync = NO, changed = NO;
    NSUInteger start = NSNotFound;
    for (NSUInteger i = 0; i + 3 < length;) {
        NSUInteger prefix = 0;
        if (bytes[i] == 0 && bytes[i+1] == 0) {
            if (bytes[i+2] == 1) prefix = 3;
            else if (bytes[i+2] == 0 && bytes[i+3] == 1) prefix = 4;
        }
        if (!prefix) { i++; continue; }
        if (start != NSNotFound && i > start) [self appendNAL:bytes+start length:i-start to:avcc sync:&sync changed:&changed];
        start = i + prefix; i = start;
    }
    if (start != NSNotFound && start < length) [self appendNAL:bytes+start length:length-start to:avcc sync:&sync changed:&changed];
    if (changed && self.sps && self.pps) {
        if (_format) { CFRelease(_format); _format = NULL; }
        const uint8_t *params[] = {self.sps.bytes,self.pps.bytes}; size_t sizes[] = {self.sps.length,self.pps.length};
        OSStatus result = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, params, sizes, 4, &_format);
        if (result) NSLog(@"H264 format error %d", (int)result);
        [self.display flush];
        if (!result) {
            CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(_format);
            NSUInteger generation = self.generation;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.generation || !self.acceptsFrames) return;
                CGSize size = CGSizeMake(dimensions.width, dimensions.height);
                if (!CGSizeEqualToSize(self.encodedSize, size)) {
                    self.encodedSize = size; [self restoreFraming];
                }
                [self.view setNeedsLayout];
                if (!self.hasSourceGeometry && !CGSizeEqualToSize(size, self.streamSize)) {
                    self.streamSize = size; self.quarterTurns = 0;
                    [self followStreamOrientation]; [self.view setNeedsLayout];
                }
            });
        }
    }
    if (!_format || !avcc.length) return;
    if (self.display.status == AVQueuedSampleBufferRenderingStatusFailed) [self.display flush];
    if (!self.display.readyForMoreMediaData) return;
    CMBlockBufferRef block = NULL; CMSampleBufferRef sample = NULL;
    OSStatus result = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length, kCFAllocatorDefault, NULL, 0, avcc.length, 0, &block);
    if (!result) result = CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);
    size_t size = avcc.length;
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    if (!result) result = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 1, &timing, 1, &size, &sample);
    if (!result) {
        CFMutableDictionaryRef attachments = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(CMSampleBufferGetSampleAttachmentsArray(sample, YES),0);
        CFDictionarySetValue(attachments, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        if (!sync) CFDictionarySetValue(attachments, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
        [self.display enqueueSampleBuffer:sample];
        NSUInteger generation = self.generation;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation || !self.acceptsFrames) return;
            if (!self.showingVideo) { self.showingVideo = YES; self.instructions.hidden = YES; self.pinLabel.hidden = YES; }
        });
    }
    if (sample) CFRelease(sample); if (block) CFRelease(block);
}
- (void)appendNAL:(const uint8_t *)bytes length:(NSUInteger)length to:(NSMutableData *)output sync:(BOOL *)sync changed:(BOOL *)changed {
    if (!length || length > UINT32_MAX) return;
    uint8_t type = bytes[0] & 31;
    if (type == 7 || type == 8) {
        NSData *value = [NSData dataWithBytes:bytes length:length];
        if (type == 7 && ![value isEqualToData:self.sps]) { self.sps = value; *changed = YES; }
        if (type == 8 && ![value isEqualToData:self.pps]) { self.pps = value; *changed = YES; }
        return;
    }
    if (type == 5) *sync = YES;
    uint32_t size = CFSwapInt32HostToBig((uint32_t)length);
    [output appendBytes:&size length:4]; [output appendBytes:bytes length:length];
}
@end

@interface MirrorSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property UIWindow *window;
@end
@implementation MirrorSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [MirrorController new];
    [self.window makeKeyAndVisible];
}
@end
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options { return YES; }
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); } }
