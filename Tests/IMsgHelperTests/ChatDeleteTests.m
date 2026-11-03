#import <Foundation/Foundation.h>

static NSString *registryClassName = @"RecentlyDeletedRegistry";

static Class deleteTestClass(NSString *name) {
    if ([name isEqualToString:@"IMChatRegistry"]) return NSClassFromString(registryClassName);
    if ([name hasPrefix:@"IM"] || [name hasPrefix:@"IDS"]) return Nil;
    return NSClassFromString(name);
}
#define NSClassFromString deleteTestClass
#import "../../Sources/IMsgHelper/IMsgInjected.m"
#undef NSClassFromString

static NSUInteger failures;
static NSMutableArray<NSString *> *calls;
static id fixtureChat;
static NSArray *movedChats;
static NSDate *movedDate;
static BOOL movedSynchronously;
static BOOL movedWithCompletion;

// Registries that only expose the permanent removal selectors. The helper
// must never fall back to them: they erase the chat and skip Recently Deleted.
@interface PermanentDeleteRegistry : NSObject
@end
@implementation PermanentDeleteRegistry
+ (id)sharedInstance { return [self new]; }
- (id)existingChatWithGUID:(NSString *)guid {
    [calls addObject:@"existingChatWithGUID:"];
    return [guid isEqualToString:@"iMessage;-;+15551234567"] ? fixtureChat : nil;
}
- (void)deleteChat:(id)chat { [calls addObject:@"deleteChat:"]; }
- (void)_chat_remove:(id)chat { [calls addObject:@"_chat_remove:"]; }
@end

@interface RecentlyDeletedRegistry : PermanentDeleteRegistry
@end
@implementation RecentlyDeletedRegistry
- (void)moveMessagesInChatsToRecentlyDeleted:(NSArray *)chats
                                  deleteDate:(NSDate *)date
                               synchronously:(BOOL)synchronously
                           completionHandler:(void (^)(void))completion {
    [calls addObject:@"moveMessagesInChatsToRecentlyDeleted:"];
    movedChats = chats;
    movedDate = date;
    movedSynchronously = synchronously;
    movedWithCompletion = completion != nil;
    if (completion) completion();
}
@end

static NSDictionary *invokeDelete(NSString *registry, NSString *chatGuid) {
    registryClassName = registry;
    calls = [NSMutableArray array];
    movedChats = nil;
    movedDate = nil;
    movedSynchronously = NO;
    movedWithCompletion = NO;
    return processV2Envelope(@{
        @"id": @"delete-proof",
        @"action": @"delete-chat",
        @"params": @{@"chatGuid": chatGuid}
    });
}

static NSDictionary *selectorsFor(NSString *registry) {
    registryClassName = registry;
    return handleStatus(0, @{})[@"selectors"];
}

static BOOL isNotStarted(NSDictionary *response) {
    return ![response[@"success"] boolValue]
        && [response[@"delivery_disposition"] isEqualToString:@"not_started"];
}

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

int main(void) {
    @autoreleasepool {
        fixtureChat = [NSObject new];
        NSString *guid = @"iMessage;-;+15551234567";

        NSDate *before = [NSDate date];
        NSDictionary *moved = invokeDelete(@"RecentlyDeletedRegistry", guid);
        check([moved[@"success"] boolValue], @"Recently Deleted move succeeds");
        check([calls containsObject:@"moveMessagesInChatsToRecentlyDeleted:"],
              @"Move the chat to Recently Deleted");
        check(![calls containsObject:@"deleteChat:"] && ![calls containsObject:@"_chat_remove:"],
              @"Never call a permanent removal selector");
        check(movedChats.count == 1 && movedChats.firstObject == fixtureChat, @"Move only the resolved chat");
        check(movedDate && [movedDate timeIntervalSinceDate:before] >= 0
                  && [movedDate timeIntervalSinceNow] <= 0,
              @"Stamp the deletion with the current time");
        check(movedSynchronously, @"Move synchronously");
        check(movedWithCompletion, @"Pass a completion handler");
        check([moved[@"data"][@"method"] isEqualToString:
                  @"moveMessagesInChatsToRecentlyDeleted:deleteDate:synchronously:completionHandler:"],
              @"Report the Recently Deleted method");
        check([moved[@"data"][@"deleted"] boolValue], @"Report the chat as deleted");

        NSDictionary *refused = invokeDelete(@"PermanentDeleteRegistry", guid);
        check(isNotStarted(refused), @"Refuse as not_started without the Recently Deleted selector");
        check(calls.count == 0, @"Refuse before resolving or removing the chat");
        check([refused[@"error"] containsString:@"moveMessagesInChatsToRecentlyDeleted:"],
              @"Name the missing selector");

        NSDictionary *missing = invokeDelete(@"RecentlyDeletedRegistry", @"iMessage;-;+15550000000");
        check(isNotStarted(missing), @"Unknown chat is refused as not_started");
        check(![calls containsObject:@"moveMessagesInChatsToRecentlyDeleted:"],
              @"Unknown chat is never deleted");

        NSDictionary *empty = invokeDelete(@"RecentlyDeletedRegistry", @"");
        check(isNotStarted(empty) && calls.count == 0, @"Missing chatGuid is refused as not_started");

        NSDictionary *selectors = selectorsFor(@"RecentlyDeletedRegistry");
        check([selectors[@"moveChatToRecentlyDeleted"] boolValue], @"Advertise Recently Deleted move");
        selectors = selectorsFor(@"PermanentDeleteRegistry");
        check(![selectors[@"moveChatToRecentlyDeleted"] boolValue], @"Hide missing Recently Deleted move");
        check(!selectors[@"deleteChat"] && !selectors[@"removeChat"],
              @"Stop advertising permanent removal selectors");

        printf("Bridge chat-delete tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
