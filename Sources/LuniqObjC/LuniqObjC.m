#import "LuniqObjC.h"
#if __has_include(<LuniqSDK/LuniqSDK-Swift.h>)
#import <LuniqSDK/LuniqSDK-Swift.h>
#else
#import "LuniqSDK-Swift.h"
#endif

@implementation LuniqObjC

+ (void)startWithApiKey:(NSString *)apiKey endpoint:(NSString *)endpoint environment:(NSString *)env {
    [[Luniq shared] startWithApiKey:apiKey endpoint:endpoint environment:env];
}

+ (void)trackEvent:(NSString *)name properties:(NSDictionary<NSString *, id> *)props {
    [[Luniq shared] track:name properties:props];
}

+ (void)screen:(NSString *)name properties:(NSDictionary<NSString *, id> *)props {
    [[Luniq shared] screen:name properties:props];
}

+ (void)identifyVisitor:(NSString *)visitorId account:(NSString *)accountId traits:(NSDictionary *)traits {
    [[Luniq shared] identifyWithVisitorId:visitorId accountId:accountId traits:traits];
}

+ (void)flush {
    [[Luniq shared] flush];
}

+ (void)optOut:(BOOL)optOut {
    [[Luniq shared] optOut:optOut];
}

+ (void)startRecording { [[Luniq shared] startRecording]; }
+ (void)stopRecording  { [[Luniq shared] stopRecording]; }
+ (void)showFeedback:(NSString *)kind { [[Luniq shared] showFeedback:(kind ?: @"idea")]; }
+ (void)refreshInApp { [[Luniq shared] refreshInApp]; }

@end
