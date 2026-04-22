#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <zlib.h>

// ─────────────────────────────────────────────────────────────────────────────
// 开关（volatile 保证多线程安全）+ 本地持久化
// ─────────────────────────────────────────────────────────────────────────────
static volatile BOOL gA = YES;
static volatile BOOL gB = YES;

static void ld(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gA = [d objectForKey:@"sw_a"] ? [[d objectForKey:@"sw_a"] boolValue] : YES;
    gB = [d objectForKey:@"sw_b"] ? [[d objectForKey:@"sw_b"] boolValue] : YES;
}

static void svA(BOOL v) {
    gA = v;
    [[NSUserDefaults standardUserDefaults] setObject:@(v) forKey:@"sw_a"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static void svB(BOOL v) {
    gB = v;
    [[NSUserDefaults standardUserDefaults] setObject:@(v) forKey:@"sw_b"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// ─────────────────────────────────────────────────────────────────────────────
// gzip
// ─────────────────────────────────────────────────────────────────────────────
static NSData *inf(NSData *d) {
    if (!d || d.length == 0) return d;
    z_stream s = {0};
    s.zalloc = Z_NULL; s.zfree = Z_NULL; s.opaque = Z_NULL;
    s.avail_in = (uInt)d.length;
    s.next_in  = (Bytef *)d.bytes;
    if (inflateInit2(&s, 15 + 32) != Z_OK) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:d.length * 4];
    unsigned char buf[32768];
    int r;
    do {
        s.avail_out = sizeof(buf); s.next_out = buf;
        r = inflate(&s, Z_NO_FLUSH);
        if (r == Z_STREAM_ERROR || r == Z_DATA_ERROR || r == Z_MEM_ERROR) {
            inflateEnd(&s); return nil;
        }
        [out appendBytes:buf length:sizeof(buf) - s.avail_out];
    } while (s.avail_out == 0 && r != Z_STREAM_END);
    inflateEnd(&s);
    return out;
}

static NSData *def(NSData *d) {
    if (!d || d.length == 0) return d;
    z_stream s = {0};
    s.zalloc = Z_NULL; s.zfree = Z_NULL; s.opaque = Z_NULL;
    if (deflateInit2(&s, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
    s.avail_in = (uInt)d.length; s.next_in = (Bytef *)d.bytes;
    NSMutableData *out = [NSMutableData dataWithCapacity:d.length + 128];
    unsigned char buf[32768];
    int r;
    do {
        s.avail_out = sizeof(buf); s.next_out = buf;
        r = deflate(&s, Z_FINISH);
        [out appendBytes:buf length:sizeof(buf) - s.avail_out];
    } while (r == Z_OK);
    deflateEnd(&s);
    return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// 内部辅助
// ─────────────────────────────────────────────────────────────────────────────
static const char *kHW = "iPad8,1";

static NSData *repDev(NSData *body, const char *toDev) {
    if (!body || body.length == 0) return body;
    @try {
        NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!s || s.length == 0) return body;
        NSError *err = nil;
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"name=\"device\"\\s*\r?\n\\s*\r?\n[^\r\n]+"
            options:NSRegularExpressionCaseInsensitive error:&err];
        if (!re || err) return body;
        NSString *rep = [NSString stringWithFormat:@"name=\"device\"\r\n\r\n%s", toDev];
        NSMutableString *ms = [s mutableCopy];
        NSArray *m = [re matchesInString:ms options:0 range:NSMakeRange(0, ms.length)];
        if (m.count == 0) return body;
        for (NSTextCheckingResult *r in [m reverseObjectEnumerator]) {
            [ms replaceCharactersInRange:r.range withString:rep];
        }
        NSData *out = [ms dataUsingEncoding:NSUTF8StringEncoding];
        return out.length ? out : body;
    } @catch (NSException *e) {
        return body;
    }
}

static inline BOOL isOSS(NSURL *url) {
    if (!url || !url.host) return NO;
    if (!gB) return NO;
    return [url.host containsString:@"oss.work.weixin.qq.com"] &&
           [url.path containsString:@"oss_log"];
}

// ─────────────────────────────────────────────────────────────────────────────
// 原始方法实现保存（union 避免 void* 与函数指针互转的 C 限制）
// ─────────────────────────────────────────────────────────────────────────────
typedef void (*fn1_t)(id, SEL, NSData *);
typedef NSURLSessionUploadTask *(*fn2_t)(id, SEL, NSURLRequest *, NSData *);
typedef UIUserInterfaceIdiom (*fn3_t)(id, SEL);
typedef void (*fn4_t)(id, SEL, CGRect);

static fn1_t f1 = NULL;
static fn2_t f2 = NULL;
static fn3_t f3 = NULL;
static fn4_t f4 = NULL;

// ─────────────────────────────────────────────────────────────────────────────
// Hook 实现
// ─────────────────────────────────────────────────────────────────────────────
static void h1(id slf, SEL _cmd, NSData *body) {
    if (!body) { f1(slf, _cmd, body); return; }
    @try {
        NSURL *url = [slf URL];
        if (!url) { f1(slf, _cmd, body); return; }
        if (isOSS(url)) {
            NSData *dec = inf(body);
            if (dec) {
                NSData *rep = repDev(dec, kHW);
                if (![rep isEqualToData:dec]) {
                    NSData *renc = def(rep);
                    if (renc) { f1(slf, _cmd, renc); return; }
                }
            } else {
                NSData *rep = repDev(body, kHW);
                if (![rep isEqualToData:body]) { f1(slf, _cmd, rep); return; }
            }
        }
        f1(slf, _cmd, body);
    } @catch (NSException *e) {
        f1(slf, _cmd, body);
    }
}

static NSURLSessionUploadTask *h2(id slf, SEL _cmd, NSURLRequest *req, NSData *data) {
    if (!data || !req.URL) return f2(slf, _cmd, req, data);
    @try {
        if (isOSS(req.URL)) {
            NSData *dec = inf(data);
            if (dec) {
                NSData *rep = repDev(dec, kHW);
                if (![rep isEqualToData:dec]) {
                    NSData *renc = def(rep);
                    if (renc) return f2(slf, _cmd, req, renc);
                }
            } else {
                NSData *rep = repDev(data, kHW);
                if (![rep isEqualToData:data]) return f2(slf, _cmd, req, rep);
            }
        }
        return f2(slf, _cmd, req, data);
    } @catch (NSException *e) {
        return f2(slf, _cmd, req, data);
    }
}

static UIUserInterfaceIdiom h3(id slf, SEL _cmd) {
    if (gA) return UIUserInterfaceIdiomPad;
    return f3(slf, _cmd);
}

static void h4(id slf, SEL _cmd, CGRect frame) {
    if (gA) {
        @try {
            if (slf && [slf respondsToSelector:@selector(inputViewStyle)]) {
                NSInteger st = 0;
                st = ((NSInteger (*)(id, SEL))[slf methodForSelector:@selector(inputViewStyle)])(slf, @selector(inputViewStyle));
                if (st == 2) {
                    CGFloat sw = [UIScreen mainScreen].bounds.size.width;
                    CGFloat sh = [UIScreen mainScreen].bounds.size.height;
                    if (frame.size.width > sw) frame.size.width = sw;
                    if (frame.size.height > sh) frame.size.height = sh * 0.5;
                }
            }
        } @catch (NSException *e) {}
    }
    f4(slf, _cmd, frame);
}

// ─────────────────────────────────────────────────────────────────────────────
// 安装（由 +load 调用）
// ─────────────────────────────────────────────────────────────────────────────
static void ins(void) {
    Class c1 = objc_getClass("NSMutableURLRequest");
    Class c2 = objc_getClass("NSURLSession");
    Class c3 = objc_getClass("UIDevice");
    Class c4 = objc_getClass("UIInputView");

    SEL s1 = @selector(setHTTPBody:);
    SEL s2 = @selector(uploadTaskWithRequest:fromData:);
    SEL s3 = @selector(userInterfaceIdiom);
    SEL s4 = @selector(setFrame:);

    if (c1) {
        Method m = class_getInstanceMethod(c1, s1);
        if (m) { f1 = (fn1_t)method_getImplementation(m); method_setImplementation(m, (IMP)h1); }
    }
    if (c2) {
        Method m = class_getInstanceMethod(c2, s2);
        if (m) { f2 = (fn2_t)method_getImplementation(m); method_setImplementation(m, (IMP)h2); }
    }
    if (c3) {
        Method m = class_getInstanceMethod(c3, s3);
        if (m) { f3 = (fn3_t)method_getImplementation(m); method_setImplementation(m, (IMP)h3); }
    }
    if (c4) {
        Method m = class_getInstanceMethod(c4, s4);
        if (m) { f4 = (fn4_t)method_getImplementation(m); method_setImplementation(m, (IMP)h4); }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 悬浮面板
// ─────────────────────────────────────────────────────────────────────────────
@interface WWPanelM : NSObject
+ (void)install;
@end

@interface WWPanelV : UIView
@property (nonatomic, strong) UISwitch *swA;
@property (nonatomic, strong) UISwitch *swB;
@end

// ─────────────────────────────────────────────────────────────────────────────
// 悬浮球管理器
// ─────────────────────────────────────────────────────────────────────────────
@implementation WWPanelM

static UIButton *_ball = nil;
static UIView *_panel = nil;

+ (void)load {
    ins();
    ld();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self install];
    });
}

+ (void)install {
    if (_ball) return;
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self install];
        });
        return;
    }

    CGFloat pW = 260, pH = 240, bR = 25;

    _ball = [UIButton buttonWithType:UIButtonTypeCustom];
    _ball.frame = CGRectMake(win.bounds.size.width - bR * 2 - 16,
                             win.bounds.size.height * 0.4f,
                             bR * 2, bR * 2);
    _ball.alpha = 0;
    _ball.backgroundColor = [UIColor clearColor];
    _ball.layer.shadowColor = [UIColor blackColor].CGColor;
    _ball.layer.shadowOffset = CGSizeMake(0, 2);
    _ball.layer.shadowRadius = 4;
    _ball.layer.shadowOpacity = 0.4;
    _ball.layer.masksToBounds = NO;

    NSData *imgData = [NSData dataWithContentsOfURL:
        [NSURL URLWithString:@"https://i.ibb.co/q9G9nNq/031-B2851-ABCA-400-F-9-F20-01380-AF49-F12.jpg"]];
    UIImage *ballImg = [UIImage imageWithData:imgData];
    UIImageView *imgView = [[UIImageView alloc] initWithImage:ballImg];
    imgView.frame = CGRectMake(0, 0, bR * 2, bR * 2);
    imgView.contentMode = UIViewContentModeScaleAspectFill;
    imgView.layer.cornerRadius = bR;
    imgView.layer.masksToBounds = YES;
    [_ball addSubview:imgView];

    [_ball setTitle:@"" forState:UIControlStateNormal];
    [_ball addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [_ball addGestureRecognizer:pan];
    [win addSubview:_ball];

    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, pW, pH)];
    _panel.backgroundColor = [UIColor clearColor];
    _panel.userInteractionEnabled = YES;
    _panel.alpha = 0;
    _panel.transform = CGAffineTransformMakeScale(0.01, 0.01);

    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    [_panel addGestureRecognizer:dismiss];

    WWPanelV *pv = [[WWPanelV alloc] initWithFrame:CGRectMake(0, 0, pW, pH)];
    [_panel addSubview:pv];
    _panel.center = CGPointMake(win.bounds.size.width / 2, win.bounds.size.height / 2);
    [win addSubview:_panel];

    UITapGestureRecognizer *triple = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTripleTap:)];
    triple.numberOfTapsRequired = 2;
    triple.numberOfTouchesRequired = 3;
    [win addGestureRecognizer:triple];
}

+ (void)togglePanel {
    UIView *p = _panel;
    if (!p || !p.superview) return;
    BOOL vis = (p.alpha > 0.5f);
    if (vis) {
        [UIView animateWithDuration:0.2 animations:^{
            p.transform = CGAffineTransformMakeScale(0.01, 0.01);
            p.alpha = 0;
        } completion:nil];
    } else {
        p.transform = CGAffineTransformMakeScale(0.01, 0.01);
        p.alpha = 0;
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:0 animations:^{
            p.transform = CGAffineTransformIdentity;
            p.alpha = 1;
        } completion:nil];
    }
}

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIButton *b = _ball;
    if (!b || !b.superview) return;
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint pt = [pan locationInView:b.superview];
        b.center = pt;
    }
}

+ (void)handleTripleTap:(UITapGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateEnded) return;
    UIButton *b = _ball;
    if (!b) return;
    BOOL hidden = (b.alpha < 0.5f);
    [UIView animateWithDuration:0.4 animations:^{
        b.alpha = hidden ? 1.0f : 0.0f;
    } completion:nil];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// 功能面板视图
// ─────────────────────────────────────────────────────────────────────────────
@implementation WWPanelV

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return self;

    self.backgroundColor = [[UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:0.95]
                            colorWithAlphaComponent:0.95];
    self.layer.cornerRadius = 16;
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    self.layer.shadowRadius = 12;
    self.layer.shadowOpacity = 0.5;
    self.layer.masksToBounds = NO;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"iPad Login by clozhi";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(16, 28, frame.size.width - 32, 22);
    [self addSubview:title];

    UILabel *warn = [[UILabel alloc] init];
    warn.text = @"请勿用于非法用途";
    warn.textColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.7];
    warn.font = [UIFont systemFontOfSize:9];
    warn.textAlignment = NSTextAlignmentCenter;
    warn.frame = CGRectMake(16, 52, frame.size.width - 32, 14);
    [self addSubview:warn];

    // ── Row 1: 伪装 iPad ──
    CGFloat sy = 74;

    UILabel *lbl1 = [[UILabel alloc] init];
    lbl1.text = @"伪装 iPad";
    lbl1.textColor = [UIColor whiteColor];
    lbl1.font = [UIFont systemFontOfSize:13];
    lbl1.frame = CGRectMake(16, sy, frame.size.width - 80, 20);
    [self addSubview:lbl1];

    UILabel *hint1 = [[UILabel alloc] init];
    hint1.text = @"登录时需开启，登录成功后可关闭";
    hint1.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
    hint1.font = [UIFont systemFontOfSize:10];
    hint1.frame = CGRectMake(16, sy + 20, frame.size.width - 80, 16);
    [self addSubview:hint1];

    UISwitch *sw1 = [[UISwitch alloc] init];
    sw1.onTintColor = [UIColor colorWithRed:0.25 green:0.55 blue:0.95 alpha:1.0];
    sw1.frame = CGRectMake(frame.size.width - 64, sy + 2, 50, 31);
    sw1.on = gA;
    _swA = sw1;
    [sw1 addTarget:self action:@selector(chA:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:sw1];

    UIView *sep1 = [[UIView alloc] init];
    sep1.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    sep1.frame = CGRectMake(16, sy + 44, frame.size.width - 32, 0.5);
    [self addSubview:sep1];

    // ── Row 2: 拦截 OSS ──
    CGFloat sy2 = sy + 52;

    UILabel *lbl2 = [[UILabel alloc] init];
    lbl2.text = @"拦截 OSS";
    lbl2.textColor = [UIColor whiteColor];
    lbl2.font = [UIFont systemFontOfSize:13];
    lbl2.frame = CGRectMake(16, sy2, frame.size.width - 80, 20);
    [self addSubview:lbl2];

    UILabel *hint2 = [[UILabel alloc] init];
    hint2.text = @"伪装设备标识，需开启";
    hint2.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.45];
    hint2.font = [UIFont systemFontOfSize:10];
    hint2.frame = CGRectMake(16, sy2 + 20, frame.size.width - 80, 16);
    [self addSubview:hint2];

    UISwitch *sw2 = [[UISwitch alloc] init];
    sw2.onTintColor = [UIColor colorWithRed:0.25 green:0.55 blue:0.95 alpha:1.0];
    sw2.frame = CGRectMake(frame.size.width - 64, sy2 + 2, 50, 31);
    sw2.on = gB;
    _swB = sw2;
    [sw2 addTarget:self action:@selector(chB:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:sw2];

    UIView *sep2 = [[UIView alloc] init];
    sep2.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    sep2.frame = CGRectMake(16, sy2 + 44, frame.size.width - 32, 0.5);
    [self addSubview:sep2];

    // ── TG 按钮 ──
    UIButton *tgBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    tgBtn.frame = CGRectMake(16, sy2 + 56, frame.size.width - 32, 40);
    tgBtn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    tgBtn.layer.cornerRadius = 10;
    [tgBtn setTitle:@"加入TG交流群" forState:UIControlStateNormal];
    [tgBtn setTitleColor:[[UIColor whiteColor] colorWithAlphaComponent:0.85] forState:UIControlStateNormal];
    tgBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [tgBtn addTarget:self action:@selector(openTG) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:tgBtn];

    return self;
}

- (void)chA:(UISwitch *)sw {
    svA(sw.on);
}

- (void)chB:(UISwitch *)sw {
    svB(sw.on);
}

- (void)openTG {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://t.me/iTroll886"] options:@{} completionHandler:nil];
}

@end
