#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>

static NSString *gCurrentUUID = nil;
static NSString *gCachedIDFV = nil;

static NSString *deriveUUIDFromIDFV(NSString *idfv) {
    if (!idfv || idfv.length == 0) return nil;
    
    const char *idfvBytes = [idfv UTF8String];
    size_t idfvLen = strlen(idfvBytes);
    
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(idfvBytes, (CC_LONG)idfvLen, hash);
    
    unsigned char uuidBytes[16];
    memcpy(uuidBytes, hash, 16);
    
    uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x40;
    uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80;
    
    NSUUID *newUUID = [[NSUUID alloc] initWithUUIDBytes:uuidBytes];
    return [newUUID UUIDString];
}

static NSString *getOrDeriveUUID(void) {
    @try {
        NSUUID *idfvObj = [[UIDevice currentDevice] identifierForVendor];
        if (!idfvObj) {
            NSLog(@"[FishTweak] IDFV 返回 nil");
            return [[NSUUID UUID] UUIDString];
        }
        
        NSString *idfvStr = [idfvObj UUIDString];
        if (!idfvStr || idfvStr.length != 36) {
            NSLog(@"[FishTweak] IDFV 格式异常: %@", idfvStr);
            return [[NSUUID UUID] UUIDString];
        }
        
        if (gCachedIDFV && [gCachedIDFV isEqualToString:idfvStr] && gCurrentUUID) {
            return gCurrentUUID;
        }
        
        NSString *derived = deriveUUIDFromIDFV(idfvStr);
        if (!derived) {
            return [[NSUUID UUID] UUIDString];
        }
        
        gCachedIDFV = [idfvStr copy];
        gCurrentUUID = [derived copy];
        
        NSLog(@"[FishTweak] IDFV: %@", idfvStr);
        NSLog(@"[FishTweak] 派生 IDFA: %@", derived);
        
        return derived;
    } @catch (NSException *e) {
        NSLog(@"[FishTweak] 异常: %@", e);
        return [[NSUUID UUID] UUIDString];
    }
}

%hook LSApplicationWorkspace

- (NSUUID *)deviceIdentifierForAdvertising {
    NSString *newUUIDStr = getOrDeriveUUID();
    NSUUID *newUUID = [[NSUUID alloc] initWithUUIDString:newUUIDStr];
    NSLog(@"[FishTweak] 拦截 IDFA，返回: %@", newUUIDStr);
    return newUUID;
}

%end

%hook ASIdentifierManager

- (NSUUID *)advertisingIdentifier {
    NSString *newUUIDStr = getOrDeriveUUID();
    NSUUID *newUUID = [[NSUUID alloc] initWithUUIDString:newUUIDStr];
    NSLog(@"[FishTweak] 拦截 ASIM IDFA，返回: %@", newUUIDStr);
    return newUUID;
}

%end

%hook NSUUID

- (NSString *)UUIDString {
    NSString *orig = %orig;
    if (orig && orig.length == 36 && [orig containsString:@"-"]) {
        NSString *newUUIDStr = getOrDeriveUUID();
        if (newUUIDStr) {
            return newUUIDStr;
        }
    }
    return orig;
}

%end

%ctor {
    NSLog(@"[FishTweak] 插件已加载 v1.0.0");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *uuid = getOrDeriveUUID();
        NSLog(@"[FishTweak] 预热完成，当前环境 IDFA: %@", uuid);
    });
}
