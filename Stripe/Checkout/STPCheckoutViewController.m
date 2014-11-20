//
//  STPCheckoutViewController.m
//  StripeExample
//
//  Created by Jack Flintermann on 9/15/14.
//  Copyright (c) 2014 Stripe. All rights reserved.
//

#import "STPCheckoutViewController.h"
#import "STPCheckoutOptions.h"
#import "STPToken.h"
#import "Stripe.h"
#import "STPColorUtils.h"
#import "STPCheckoutURLProtocol.h"
#import "FauxPasAnnotations.h"

@interface STPCheckoutViewController () <UIWebViewDelegate>
@property (weak, nonatomic) UIWebView *webView;
@property (weak, nonatomic) UIActivityIndicatorView *activityIndicator;
@property (nonatomic) STPCheckoutOptions *options;
@property (nonatomic) NSURL *url;
@property (nonatomic) UIStatusBarStyle previousStyle;
@property (nonatomic) NSURL *logoImageUrl;
@end

@implementation STPCheckoutViewController

static NSString *const checkoutOptionsGlobal = @"StripeCheckoutOptions";
static NSString *const checkoutRedirectPrefix = @"/-/";
static NSString *const checkoutRPCScheme = @"stripecheckout";
static NSString *const checkoutUserAgent = @"Stripe";
static NSString *const checkoutURL = @"http://checkout.stripe.com/v3/ios";

- (instancetype)initWithOptions:(STPCheckoutOptions *)options {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _options = options;
        _previousStyle = [[UIApplication sharedApplication] statusBarStyle];
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            NSString *userAgent = [[[UIWebView alloc] init] stringByEvaluatingJavaScriptFromString:@"window.navigator.userAgent"];
            if ([userAgent rangeOfString:checkoutUserAgent].location == NSNotFound) {
                userAgent = [NSString stringWithFormat:@"%@ %@/%@", userAgent, checkoutUserAgent, STPLibraryVersionNumber];
                NSDictionary *defaults = @{ @"UserAgent": userAgent };
                [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
            }
            [NSURLProtocol registerClass:[STPCheckoutURLProtocol class]];
        });
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.url = [NSURL URLWithString:checkoutURL];

    self.logoImageUrl = self.options.logoURL;
    if (self.options.logoImage && !self.options.logoURL) {
        NSString *fileName = [[NSUUID UUID] UUIDString];
        _logoImageUrl = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
        BOOL success = [UIImagePNGRepresentation(self.options.logoImage) writeToURL:self.logoImageUrl options:0 error:nil];
        if (!success) {
            self.logoImageUrl = nil;
        }
    }

    UIWebView *webView = [[UIWebView alloc] init];
    [self.view addSubview:webView];
    [webView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|-0-[webView]-0-|"
                                                                      options:NSLayoutFormatDirectionLeadingToTrailing
                                                                      metrics:nil
                                                                        views:NSDictionaryOfVariableBindings(webView)]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|-0-[webView]-0-|"
                                                                      options:NSLayoutFormatDirectionLeadingToTrailing
                                                                      metrics:nil
                                                                        views:NSDictionaryOfVariableBindings(webView)]];
    webView.keyboardDisplayRequiresUserAction = NO;
    webView.backgroundColor = [UIColor whiteColor];
    self.view.backgroundColor = [UIColor whiteColor];
    if (self.options.logoColor) {
        webView.backgroundColor = self.options.logoColor;
    }
    [webView loadRequest:[NSURLRequest requestWithURL:self.url]];
    webView.delegate = self;
    self.webView = webView;

    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:activityIndicator];
    self.activityIndicator = activityIndicator;
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 70000
- (UIStatusBarStyle)preferredStatusBarStyle {
    if (self.options.logoColor) {
        FAUXPAS_IGNORED_IN_METHOD(APIAvailability);
        return [STPColorUtils colorIsLight:self.options.logoColor] ? UIStatusBarStyleDefault : UIStatusBarStyleLightContent;
    }
    return UIStatusBarStyleDefault;
}
#endif

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.activityIndicator.center = self.view.center;
}

- (void)cleanup {
    [[UIApplication sharedApplication] setStatusBarStyle:self.previousStyle animated:YES];
    if ([self.logoImageUrl isFileURL]) {
        [[NSFileManager defaultManager] removeItemAtURL:self.logoImageUrl error:nil];
    }
}

- (void)setLogoColor:(UIColor *)color {
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 70000
    self.options.logoColor = color;
    if ([self respondsToSelector:@selector(setNeedsStatusBarAppearanceUpdate)]) {
        FAUXPAS_IGNORED_IN_METHOD(APIAvailability);
        [[UIApplication sharedApplication] setStatusBarStyle:[self preferredStatusBarStyle] animated:YES];
        [self setNeedsStatusBarAppearanceUpdate];
    }
#endif
}

#pragma mark - UIWebViewDelegate

- (void)webViewDidStartLoad:(UIWebView *)webView {
    NSString *optionsJavaScript =
        [NSString stringWithFormat:@"window.%@ = %@;", checkoutOptionsGlobal, [self.options stringifiedJSONRepresentationForImageURL:self.logoImageUrl]];
    [webView stringByEvaluatingJavaScriptFromString:optionsJavaScript];
    [self.activityIndicator startAnimating];
}

- (BOOL)webView:(__unused UIWebView *)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(UIWebViewNavigationType)navigationType {
    NSURL *url = request.URL;
    if (navigationType == UIWebViewNavigationTypeLinkClicked && [url.host isEqualToString:self.url.host] &&
        [url.path rangeOfString:checkoutRedirectPrefix].location == 0) {
        [[UIApplication sharedApplication] openURL:url];
        return NO;
    }
    if ([url.scheme isEqualToString:checkoutRPCScheme]) {
        NSString *event = url.host;
        NSString *path = [url.path componentsSeparatedByString:@"/"][1];
        NSDictionary *payload = nil;
        if (path != nil) {
            payload = [NSJSONSerialization JSONObjectWithData:[path dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }

        if ([event isEqualToString:@"CheckoutDidOpen"]) {
            if (payload[@"logoColor"]) {
                [self setLogoColor:[STPColorUtils colorForHexCode:payload[@"logoColor"]]];
            }
        } else if ([event isEqualToString:@"CheckoutDidTokenize"]) {
            STPToken *token = nil;
            if (payload != nil && payload[@"token"] != nil) {
                token = [[STPToken alloc] initWithAttributeDictionary:payload[@"token"]];
            }
            [self.delegate checkoutController:self
                               didCreateToken:token
                                   completion:^(STPPaymentAuthorizationStatus status) {
                                       if (status == STPPaymentAuthorizationStatusSuccess) {
                                           // @reggio: do something here like [self.webView
                                           // stringByEvaluatingStringFromJavascript:@"showCheckoutSuccessAnimation();"]
                                           // that should probably trigger the "CheckoutDidFinish" event when the animation is complete
                                       } else {
                                           // @reggio: do something here like [self.webView
                                           // stringByEvaluatingStringFromJavascript:@"showCheckoutFailureAnimation();"]
                                           // that should probably trigger the "CheckoutDidError" event when the animation is complete
                                       }
                                   }];
        } else if ([event isEqualToString:@"CheckoutDidFinish"]) {
            [self cleanup];
            [self.delegate checkoutControllerDidFinish:self];
        } else if ([url.host isEqualToString:@"CheckoutDidClose"]) {
            [self.delegate checkoutControllerDidCancel:self];
            [self cleanup];
        } else if ([event isEqualToString:@"CheckoutDidError"]) {
            [self cleanup];
            NSError *error = [[NSError alloc] initWithDomain:StripeDomain code:STPCheckoutError userInfo:payload];
            [self.delegate checkoutController:self didFailWithError:error];
        }
        return NO;
    }
    return navigationType == UIWebViewNavigationTypeOther;
}

- (void)webViewDidFinishLoad:(__unused UIWebView *)webView {
    [UIView animateWithDuration:0.2
        animations:^{ self.activityIndicator.alpha = 0; }
        completion:^(__unused BOOL finished) { [self.activityIndicator stopAnimating]; }];
}

- (void)webView:(__unused UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [self.activityIndicator stopAnimating];
    [self cleanup];
    [self.delegate checkoutController:self didFailWithError:error];
}

@end
