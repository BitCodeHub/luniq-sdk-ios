#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LuniqObjC : NSObject
+ (void)startWithApiKey:(NSString *)apiKey endpoint:(NSString *)endpoint environment:(NSString *)env;
+ (void)trackEvent:(NSString *)name properties:(nullable NSDictionary<NSString *, id> *)props;
+ (void)screen:(NSString *)name properties:(nullable NSDictionary<NSString *, id> *)props;
+ (void)identifyVisitor:(NSString *)visitorId account:(nullable NSString *)accountId traits:(nullable NSDictionary *)traits;
+ (void)flush;
+ (void)optOut:(BOOL)optOut;
+ (void)startRecording;
+ (void)stopRecording;
+ (void)showFeedback:(nullable NSString *)kind;
+ (void)refreshInApp;
@end

NS_ASSUME_NONNULL_END
