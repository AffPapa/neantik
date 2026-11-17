// Disposable GitHub-hosted macOS VM only. This is not NeAntik code.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <libproc.h>
#import <pwd.h>
#import <limits.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static NSString *const kService = @"synthetic.neantik.keychain.fixture.v1";
static NSString *const kOwnerAccount = @"synthetic-owner-a";
static NSString *const kOtherAccount = @"synthetic-owner-b";
static NSString *const kDecoyAccount = @"synthetic-decoy-only";
static const char kFakePassword[] = "only-disposable-ci-fixture";
static NSString *const kFakeValue = @"not-a-user-secret";

static BOOL inside(NSString *path, NSString *root) {
    NSString *p = [path stringByResolvingSymlinksInPath].stringByStandardizingPath;
    NSString *r = [root stringByResolvingSymlinksInPath].stringByStandardizingPath;
    return [p hasPrefix:[r stringByAppendingString:@"/"]];
}

// Safety interlock: reject local execution before calling ANY Security API.
static BOOL permitted(NSString *dir) {
    struct passwd *pw = getpwuid(getuid());
    const char *temp = getenv("RUNNER_TEMP");
    const char *actions = getenv("GITHUB_ACTIONS");
    const char *runner = getenv("RUNNER_ENVIRONMENT");
    char executable[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (!pw || strcmp(pw->pw_name, "runner") || !temp || !actions || !runner ||
        strcmp(actions, "true") || strcmp(runner, "github-hosted") ||
        proc_pidpath(getpid(), executable, sizeof(executable)) <= 0) return NO;
    NSString *root = [NSString stringWithUTF8String:temp];
    NSString *self = [NSString stringWithUTF8String:executable];
    return root && self && [root hasPrefix:@"/Users/runner/"] &&
           inside(dir, root) && inside(self, dir) &&
           [[dir lastPathComponent] hasPrefix:@"neantik-keychain-ci-"];
}

static OSStatus openFixture(NSString *dir, NSString *name, SecKeychainRef *keychain) {
    NSString *path = [dir stringByAppendingPathComponent:name];
    OSStatus status = SecKeychainOpen(path.fileSystemRepresentation, keychain);
    if (status != errSecSuccess) return status;
    return SecKeychainUnlock(*keychain, (UInt32)strlen(kFakePassword), kFakePassword, true);
}

static OSStatus findFake(SecKeychainRef keychain, NSString *account, CFTypeRef *result) {
    // The search list is explicitly limited to this disposable keychain.
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        (__bridge id)kSecReturnRef: @YES,
        (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUIFail
    };
    return SecItemCopyMatching((__bridge CFDictionaryRef)query, result);
}

static BOOL belongsTo(SecKeychainItemRef item, SecKeychainRef keychain) {
    SecKeychainRef actual = NULL;
    OSStatus status = SecKeychainItemCopyKeychain(item, &actual);
    BOOL equal = (status == errSecSuccess && actual && CFEqual(actual, keychain));
    if (actual) CFRelease(actual);
    return equal;
}

typedef struct { OSStatus search; OSStatus deletion; BOOL keychainVerified; BOOL attempted; } DeleteResult;
static DeleteResult deleteFake(SecKeychainRef keychain, NSString *account) {
    CFTypeRef item = NULL;
    DeleteResult result = { .search = findFake(keychain, account, &item), .deletion = INT_MIN, .keychainVerified = NO, .attempted = NO };
    if (result.search != errSecSuccess || !item) return result;
    result.keychainVerified = CFGetTypeID(item) == SecKeychainItemGetTypeID() && belongsTo((SecKeychainItemRef)item, keychain);
    if (!result.keychainVerified) { CFRelease(item); return result; }
    // Delete only the exact in-memory ref returned from the bounded query.
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
        (__bridge id)kSecMatchItemList: @[(__bridge id)item],
        (__bridge id)kSecUseAuthenticationUI: (__bridge id)kSecUseAuthenticationUIFail
    };
    result.attempted = YES;
    result.deletion = SecItemDelete((__bridge CFDictionaryRef)query);
    CFRelease(item);
    return result;
}

static OSStatus createFake(SecKeychainRef keychain, NSString *account, NSString *ownerPath) {
    SecTrustedApplicationRef owner = NULL;
    SecAccessRef access = NULL;
    NSDictionary *attrs = nil;
    OSStatus status = SecTrustedApplicationCreateFromPath(ownerPath.fileSystemRepresentation, &owner);
    if (status != errSecSuccess || !owner) goto done;
    status = SecAccessCreate(CFSTR("synthetic only"), (__bridge CFArrayRef)@[(__bridge id)owner], &access);
    if (status != errSecSuccess || !access) goto done;
    attrs = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: [kFakeValue dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecUseKeychain: (__bridge id)keychain,
        (__bridge id)kSecAttrAccess: (__bridge id)access
    };
    status = SecItemAdd((__bridge CFDictionaryRef)attrs, NULL);
done:
    if (access) CFRelease(access);
    if (owner) CFRelease(owner);
    return status;
}

// Paths are read only in the disposable VM and stored only in an owner-only
// temporary file. They are never printed, exported, or used as query inputs.
static NSDictionary *snapshot(void) {
    CFArrayRef list = NULL; SecKeychainRef def = NULL;
    OSStatus ls = SecKeychainCopySearchList(&list);
    OSStatus ds = SecKeychainCopyDefault(&def);
    NSMutableArray *paths = [NSMutableArray array];
    BOOL okList = ls == errSecSuccess && list;
    if (okList) {
        for (id obj in (__bridge NSArray *)list) {
            char buf[PATH_MAX] = {0}; UInt32 size = sizeof(buf);
            if (SecKeychainGetPath((__bridge SecKeychainRef)obj, &size, buf) != errSecSuccess) { okList = NO; break; }
            NSString *str = [NSString stringWithUTF8String:buf];
            if (!str) { okList = NO; break; }
            [paths addObject:str];
        }
    }
    NSString *defaultPath = @""; BOOL okDefault = ds == errSecSuccess && def;
    if (okDefault) {
        char buf[PATH_MAX] = {0}; UInt32 size = sizeof(buf);
        if (SecKeychainGetPath(def, &size, buf) != errSecSuccess) okDefault = NO;
        else { defaultPath = [NSString stringWithUTF8String:buf]; if (!defaultPath) okDefault = NO; }
    }
    if (list) CFRelease(list); if (def) CFRelease(def);
    return @{ @"listOK": @(okList), @"defaultOK": @(okDefault),
              @"list": okList ? paths : @[], @"default": okDefault ? defaultPath : @"" };
}
static void reportSnapshot(NSString *dir, NSString *event) {
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"baseline.plist"]];
    NSDictionary *baseline = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL] : nil;
    NSDictionary *current = snapshot();
    int listEqual = (baseline && [baseline[@"listOK"] boolValue] && [current[@"listOK"] boolValue]) ? (int)[baseline[@"list"] isEqual:current[@"list"]] : -1;
    int defaultEqual = (baseline && [baseline[@"defaultOK"] boolValue] && [current[@"defaultOK"] boolValue]) ? (int)[baseline[@"default"] isEqual:current[@"default"]] : -1;
    // event is a fixed literal selected by code, never external input.
    printf("{\"event\":\"%s\",\"searchListEqual\":%d,\"defaultEqual\":%d}\n", event.UTF8String, listEqual, defaultEqual);
}
static int setup(NSString *dir) {
    NSDictionary *before = snapshot();
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:before format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
    if (!data || ![data writeToFile:[dir stringByAppendingPathComponent:@"baseline.plist"] options:NSDataWritingAtomic error:NULL]) return 2;
    SecKeychainRef mainKeychain = NULL, decoy = NULL;
    NSString *path = [dir stringByAppendingPathComponent:@"fixture.keychain-db"];
    NSString *decoyPath = [dir stringByAppendingPathComponent:@"decoy.keychain-db"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path] || [[NSFileManager defaultManager] fileExistsAtPath:decoyPath]) return 2;
    OSStatus created = SecKeychainCreate(path.fileSystemRepresentation, (UInt32)strlen(kFakePassword), kFakePassword, false, NULL, &mainKeychain);
    OSStatus decoyCreated = created == errSecSuccess ? SecKeychainCreate(decoyPath.fileSystemRepresentation, (UInt32)strlen(kFakePassword), kFakePassword, false, NULL, &decoy) : INT_MIN;
    printf("{\"event\":\"setup\",\"create\":%d,\"decoyCreate\":%d}\n", (int)created, (int)decoyCreated);
    reportSnapshot(dir, @"afterCreate");
    if (decoy) CFRelease(decoy);
    if (created != errSecSuccess || decoyCreated != errSecSuccess || !mainKeychain) { if (mainKeychain) CFRelease(mainKeychain); return 3; }
    NSString *ownerA = [dir stringByAppendingPathComponent:@"OwnerA"];
    OSStatus a = createFake(mainKeychain, kOwnerAccount, ownerA);
    printf("{\"event\":\"seedA\",\"status\":%d}\n", (int)a);
    CFRelease(mainKeychain);
    return a == errSecSuccess ? 0 : 4;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSString *dir = [NSString stringWithUTF8String:argv[2]];
        if (!dir || !permitted(dir)) { fputs("fixture refused: disposable runner required\n", stderr); return 77; }
        NSString *role = [NSString stringWithUTF8String:argv[1]];
        NSString *name = [[[NSProcessInfo processInfo] arguments][0] lastPathComponent];
        if (![name isEqualToString:@"OwnerA"] && ![name isEqualToString:@"OwnerB"]) return 64;
        OSStatus interaction = SecKeychainSetUserInteractionAllowed(false);
        if (interaction != errSecSuccess) { printf("{\"event\":\"noninteractive\",\"status\":%d}\n", (int)interaction); return 5; }
        if ([name isEqualToString:@"OwnerA"] && [role isEqualToString:@"setup"]) return setup(dir);
        if ([name isEqualToString:@"OwnerA"] && [role isEqualToString:@"snapshot"]) { reportSnapshot(dir, @"afterSequence"); return 0; }
        SecKeychainRef keychain = NULL;
        OSStatus opened = openFixture(dir, @"fixture.keychain-db", &keychain);
        if (opened != errSecSuccess || !keychain) { printf("{\"event\":\"open\",\"status\":%d}\n", (int)opened); if (keychain) CFRelease(keychain); return 6; }
        if ([name isEqualToString:@"OwnerB"] && [role isEqualToString:@"probe"]) {
            SecKeychainRef decoy = NULL; OSStatus decoyOpened = openFixture(dir, @"decoy.keychain-db", &decoy);
            if (decoyOpened != errSecSuccess || !decoy) { printf("{\"event\":\"decoyOpen\",\"status\":%d}\n", (int)decoyOpened); CFRelease(keychain); if (decoy) CFRelease(decoy); return 7; }
            NSString *ownerB = [dir stringByAppendingPathComponent:@"OwnerB"];
            OSStatus ownSeed = createFake(keychain, kOtherAccount, ownerB);
            OSStatus decoySeed = createFake(decoy, kDecoyAccount, ownerB);
            CFTypeRef ref = NULL; OSStatus decoyInMain = findFake(keychain, kDecoyAccount, &ref); if (ref) CFRelease(ref);
            ref = NULL; OSStatus decoyFound = findFake(decoy, kDecoyAccount, &ref);
            BOOL decoyVerified = ref && CFGetTypeID(ref) == SecKeychainItemGetTypeID() && belongsTo((SecKeychainItemRef)ref, decoy);
            if (ref) CFRelease(ref);
            printf("{\"event\":\"scope\",\"ownSeed\":%d,\"decoySeed\":%d,\"decoyInMain\":%d,\"decoyFound\":%d,\"decoyVerified\":%s}\n", (int)ownSeed, (int)decoySeed, (int)decoyInMain, (int)decoyFound, decoyVerified ? "true":"false");
            CFRelease(decoy);
            if (ownSeed != errSecSuccess || decoySeed != errSecSuccess || decoyInMain != errSecItemNotFound || decoyFound != errSecSuccess || !decoyVerified) { CFRelease(keychain); return 8; }
            DeleteResult denied = deleteFake(keychain, kOwnerAccount);
            ref = NULL; OSStatus remains = findFake(keychain, kOwnerAccount, &ref); if (ref) CFRelease(ref);
            DeleteResult own = deleteFake(keychain, kOtherAccount);
            ref = NULL; OSStatus ownAfter = findFake(keychain, kOtherAccount, &ref); if (ref) CFRelease(ref);
            printf("{\"event\":\"other\",\"deniedSearch\":%d,\"deniedKeychainVerified\":%s,\"deniedAttempted\":%s,\"deniedDelete\":%d,\"matchesOwnerEdit\":%s,\"ownerStillFound\":%d,\"ownSearch\":%d,\"ownKeychainVerified\":%s,\"ownAttempted\":%s,\"ownDelete\":%d,\"ownAfter\":%d}\n", (int)denied.search, denied.keychainVerified ? "true":"false", denied.attempted ? "true":"false", (int)denied.deletion, denied.attempted && denied.deletion == errSecInvalidOwnerEdit ? "true":"false", (int)remains, (int)own.search, own.keychainVerified ? "true":"false", own.attempted ? "true":"false", (int)own.deletion, (int)ownAfter);
            CFRelease(keychain);
            return (denied.search == errSecSuccess && denied.keychainVerified && denied.attempted && denied.deletion != errSecSuccess && remains == errSecSuccess && own.search == errSecSuccess && own.keychainVerified && own.attempted && own.deletion == errSecSuccess && ownAfter == errSecItemNotFound) ? 0 : 9;
        }
        if ([name isEqualToString:@"OwnerA"] && [role isEqualToString:@"cleanup"]) {
            DeleteResult own = deleteFake(keychain, kOwnerAccount);
            CFTypeRef ref = NULL; OSStatus after = findFake(keychain, kOwnerAccount, &ref); if (ref) CFRelease(ref);
            printf("{\"event\":\"owner\",\"ownSearch\":%d,\"ownKeychainVerified\":%s,\"ownAttempted\":%s,\"ownDelete\":%d,\"ownAfter\":%d}\n", (int)own.search, own.keychainVerified ? "true":"false", own.attempted ? "true":"false", (int)own.deletion, (int)after);
            CFRelease(keychain);
            return (own.search == errSecSuccess && own.keychainVerified && own.attempted && own.deletion == errSecSuccess && after == errSecItemNotFound) ? 0 : 10;
        }
        CFRelease(keychain);
        return 64;
    }
}
