//
//  RNAccengageModule.m
//  RNAccengageModule
//
//  Created by Erik Poort on 28/07/2017.
//  Copyright (c) 2017 MediaMonks. All rights reserved.
//

#import "RNAccengageModule.h"
#import <Accengage/Accengage.h>
#import <React/RCTUtils.h>


static NSString *const kRejectCode = @"RNAccengageModule.h";
static NSString *const kPushRequested = @"pushRequested";

@implementation RNAccengageModule
BMA4SInBox      *_inbox;
NSMutableArray  *_messages;
NSMutableArray  *_loadedMessages;
int             _numLoadedMessages;

RCT_EXPORT_MODULE();

#pragma mark - Permissions

RCT_EXPORT_METHOD(
                  hasPermissions:(RCTResponseSenderBlock)promise
                  ) {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    if (notificationCenter) {
        [notificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings)
         {
             promise(@[@(settings.authorizationStatus == UNAuthorizationStatusAuthorized)]);
         }];
    } else {
        BOOL hasPermissions = [[UIApplication sharedApplication] isRegisteredForRemoteNotifications];
        promise(@[@(hasPermissions)]);
    }
}

RCT_EXPORT_METHOD(
                  updatePermissions:(BOOL)request userAction:(BOOL)userAction
                  ) {
    [self hasPermissions:^(NSArray <NSNumber *> *response)
     {
         BOOL hasPermissions = response.firstObject.boolValue;
         
         if (userAction && !hasPermissions && [[NSUserDefaults standardUserDefaults] boolForKey:kPushRequested]) {
             // There's no permissions, the user was asked before and this call is triggered by user action
             NSURL *url = [NSURL URLWithString:UIApplicationOpenSettingsURLString];
             [[UIApplication sharedApplication] openURL:url];
         } else if (request || hasPermissions) {
             // There's permissions so we are updating, or we are requesting for the first time
             [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kPushRequested];
             ACCNotificationOptions options = (ACCNotificationOptionSound | ACCNotificationOptionBadge | ACCNotificationOptionAlert | ACCNotificationOptionCarPlay);
             [[Accengage push] registerForUserNotificationsWithOptions:options];
         }
     }];
}

#pragma mark - Tracking

RCT_EXPORT_METHOD(
                  trackEvent:(NSUInteger)key
                  ) {
    [Accengage trackEvent:key];
}

RCT_EXPORT_METHOD(
                  trackEventWithCustomData:(NSUInteger)key
                  customData:(NSDictionary *)customData
                  ) {
    if (!customData ||[customData count] == 0) {
        [Accengage trackEvent:key];
        return;
    }
    
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:customData options:0 error:&error];
    
    if (error) {
        NSLog(@"Custom data is sent in unsuported type and ignored");
        [Accengage trackEvent:key];
        return;
    }
    
    NSString *jsonString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [Accengage trackEvent:key withParameters:@[jsonString]];
}

RCT_EXPORT_METHOD(
                  trackLead:(NSString *)leadLabel
                  value:(NSString *)leadValue
                  ) {
    if (!leadLabel || [leadLabel isEqualToString:@""]) {
        NSLog(@"%@: No label was supplied", kRejectCode);
        return;
    }
    if (!leadValue || [leadValue isEqualToString:@""]) {
        NSLog(@"%@: No value was supplied", kRejectCode);
        return;
    }
    
    [Accengage trackLead:leadLabel value:leadValue];
}

#pragma mark - Get Inbox Messages
//Get Message list with pagination
//@success RCTPromiseResolveBlock
//@failure BMA4SInBoxLoadingResult
RCT_EXPORT_METHOD(
                  getInboxMessages:(RCTPromiseResolveBlock)promise
                  rejecter:(RCTPromiseRejectBlock)reject
                  ){
    [self getInboxMessagesWithPageIndex:0 limit:20 successCallback:^(NSArray *response) {
        promise(response);
    } rejecter:^(NSString *code, NSString *message, NSError *error) {
        reject(code,message,error);
    }];
}


//Get Message list
//@params pageIndex
//@params limit
//@success RCTPromiseResolveBlock
//@failure BMA4SInBoxLoadingResult
RCT_EXPORT_METHOD(
                  getInboxMessagesWithPageIndex:(int)pageIndex
                  limit:(int)limit
                  successCallback:(RCTPromiseResolveBlock)promise
                  rejecter:(RCTPromiseRejectBlock)reject
                  ){
    
    //Get Accengage Inbox
    [self getAccengageInboxWithSuccess:^(BMA4SInBox *inbox) {
        _inbox = inbox;
        //Get Accengage Messsages From Index with limit
        [self getMessagesFromIndex:pageIndex limit:limit messageListCallback:^(NSArray *response) {
            promise(response);
        } rejecter:^(NSString *code, NSString *message, NSError *error) {
            reject(code,message,error);
        }];
        
    } failure:^(BMA4SInBoxLoadingResult result) {
        NSString *operation = (result == BMA4SInBoxLoadingResultCancelled ? @"Cancelled" : @"Failed");
        NSString *errorMessage = [NSString stringWithFormat:@"Inbox loading result had been %@",operation];
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(result)];
        reject(operationCode,errorMessage,nil);
    }];
}


//Get Accengage inbox
//@success BMA4SInBox
//@failure BMA4SInBoxLoadingResult
//
- (void)getAccengageInboxWithSuccess:(void (^)(BMA4SInBox *inbox))success failure:(void (^)(BMA4SInBoxLoadingResult result))failure
{
    [BMA4SInBox obtainMessagesWithCompletionHandler:^(BMA4SInBoxLoadingResult result, BMA4SInBox *inbox) {
        if(result != BMA4SInBoxLoadingResultLoaded)
        {
            failure(result);
        }else{
            success(inbox);
        }
    }];
}

//Get Message list
//@params pageIndex
//@params limit
//@success RCTPromiseResolveBlock
//@failure BMA4SInBoxLoadingResult
//
- (void)getMessagesFromIndex:(int)pageIndex limit:(int)limit messageListCallback:(RCTPromiseResolveBlock)callback rejecter:(RCTPromiseRejectBlock)reject
{
    if(_loadedMessages != nil)
    {
        NSString *errorMessage = [NSString stringWithFormat:@"There's already messages being loaded"];
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(AccengageCallIsLoading)];
        reject(operationCode,errorMessage,nil);
    }
    
    if(_messages == nil)
    {
        _messages = [NSMutableArray new];
    }
    
    if(_numLoadedMessages < _inbox.size)
    {
        int startIndex = pageIndex * limit;
        int leni  = MIN((int)_inbox.size, limit);
        
        _loadedMessages = [NSMutableArray new];
        _numLoadedMessages = leni;
        
        for (int i =  0; i < limit; i++)
        {
            int currentIndex = startIndex + i;
            //Add null object to be replaced with the async callback
            
            BMA4SInBoxMessage* cachedMessage = [_messages objectAtIndex:i];
            
            if(cachedMessage != nil)
            {
                [_loadedMessages setObject:cachedMessage atIndexedSubscript:i];
                
                //Increase the number of loaded messages
                _numLoadedMessages ++;
            }
            
            [_inbox obtainMessageAtIndex:currentIndex loaded:^(BMA4SInBoxMessage *message, NSUInteger requestedIndex) {
                [_loadedMessages setObject:message atIndexedSubscript:requestedIndex];
                
                [self resolvePromiseIfReadyWithPageIndex:pageIndex limit:limit messageCallback:^(NSArray *response) {
                    
                } rejecter:^(NSString *code, NSString *message, NSError *error) {
                    reject(code,message,error);
                }];
            } onError:^(NSUInteger requestedIndex) {
                
                //remove number of loaded messages when the service call had failed
                _numLoadedMessages--;
                
                [self resolvePromiseIfReadyWithPageIndex:pageIndex limit:limit messageCallback:^(NSArray *response) {
                    callback(response);
                } rejecter:^(NSString *code, NSString *message, NSError *error) {
                    reject(code,message,error);
                }];
            }];
        }
        
    }else{
        //PRAGMA MARK: Uncomment after delete the warning below this callback
        //        callback(@[]);
        
#pragma WARNING remove when there is Accengage Inbox Messages data
        
        NSMutableArray *dummyMessages = [self createMessagesDummyWithLimit:limit];
        callback(@[dummyMessages]);
        
    }
}

#pragma mark Create Messages Dummy
- (NSMutableArray *)createMessagesDummyWithLimit:(int)limit
{
    //Get Current Date
    NSDate* date = [NSDate date];
    NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
    NSTimeZone *destinationTimeZone = [NSTimeZone systemTimeZone];
    formatter.timeZone = destinationTimeZone;
    [formatter setDateStyle:NSDateFormatterLongStyle];
    [formatter setDateFormat:@"MM/dd/yyyy hh:mma"];
    NSString* dateString = [formatter stringFromDate:date];
    
    NSDictionary *messageData = @{@"type"        : @"message",
                                  @"title"       : @"Welcome Message",
                                  @"body"        : @"This is a test message",
                                  @"timestamp"   : dateString,
                                  @"category"    : @"Message's Category",
                                  @"sender"      : @"Sender",
                                  @"read"        : @false,
                                  @"archived"    : @false,
                                  @"customParameters" : @{}
                                  };
    
    NSDictionary *errorMessageData = [self getErrorMessageDictionary];
    
    NSMutableArray *messages = [NSMutableArray new];

    for(int i = 0;i < limit; i++)
    {
        if(i % 2 == 0)
        {
            [messages addObject:messageData];
        }else{
            [messages addObject:errorMessageData];
        }
    }
    
    return messages;
}

RCT_EXPORT_METHOD(
                  resolvePromiseIfReadyWithPageIndex:(int)pageIndex
                  limit:(int)limit
                  messageCallback:(RCTPromiseResolveBlock)promise
                  rejecter:(RCTPromiseRejectBlock)reject
                  ){
    if(_numLoadedMessages == 0)
    {
        int startIndex = pageIndex * limit;
        int leni = MIN((int)_inbox.size, startIndex + limit);
        
        NSMutableArray *messageList = [NSMutableArray new];
        
        for(int i = 0;i < leni;i++)
        {
            int currentIndex = startIndex + i;
            BMA4SInBoxMessage *loadedMessage = [_loadedMessages objectAtIndex:currentIndex];
            
            if(loadedMessage != nil)
            {
                [_messages setObject:loadedMessage atIndexedSubscript:currentIndex];
                
                NSDictionary *messageData = [self getMessageDictionary:loadedMessage withLimitBody:true];
                [messageList addObject:messageData];
            }
            else{
                //if get message call failed
                NSDictionary *errorMessageData = [self getErrorMessageDictionary];
                [messageList addObject:errorMessageData];
            }
        }

        promise(messageList);
    }
}

- (NSDictionary *)getErrorMessageDictionary
{
    return @{@"type" : @"error"};
}

- (NSDictionary *)getMessageDictionary:(BMA4SInBoxMessage *)message withLimitBody:(bool)isLimitBody
{
    NSString *text = message.text;
    
    if(isLimitBody && message.text.length > 140)
    {
        text = [text substringToIndex:140];
    }
    
    
    //Create Message Dictionary
    NSDictionary *messageData = @{@"title"       : message.title,
                                  @"body"        : text,
                                  @"timestamp"   : message.date,
                                  @"category"    : message.category,
                                  @"sender"      : message.from,
                                  @"read"        : [NSNumber numberWithBool:message.isRead],
                                  @"archived"    : [NSNumber numberWithBool:message.isArchived],
                                  @"customParameters" : message.customParams
                                  };
    
    return messageData;
}

RCT_EXPORT_METHOD(
                  getMessageAtIndex:(int)index
                  messageCallback:(RCTPromiseResolveBlock)promise
                  rejecter:(RCTPromiseRejectBlock)reject
                  ){
    //
    //Check if the Inbox message list exists
    //
    if(_inbox != nil)
    {
        NSUInteger nsi = (NSUInteger) index;
        
        [_inbox obtainMessageAtIndex:nsi loaded:^(BMA4SInBoxMessage *message, NSUInteger requestedIndex) {
            promise(@[message]);
        } onError:^(NSUInteger requestedIndex) {
            NSString *errorMessage = @"the call to obtain message at index ";
            NSString *operationCode = [NSString stringWithFormat:@"%@",@(AccengageCallResultError)];
            reject(operationCode,errorMessage,nil);
        }];
    }else{
        NSString *errorMessage = @"You need to call to getInboxMessage before call getInboxMessageAtIndex";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(InboxMessageListNotExists)];
        reject(operationCode,errorMessage,nil);
    }
}

//Mark as read Accengage message
RCT_EXPORT_METHOD(
                  markMessageAsRead:(int)index
                  Read:(bool)read
                  callback:(RCTPromiseResolveBlock)promise
                  rejecter:(RCTPromiseRejectBlock)reject
                  ){
    if(_messages == nil)
    {
        NSString *errorMessage = @"There's no messages to mark";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(InboxMessageListNotExists)];
        reject(operationCode,errorMessage,nil);
    }
    
    if(_inbox == nil)
    {
        NSString *errorMessage = @"There's no inbox to update";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(InboxNotExists)];
        reject(operationCode,errorMessage,nil);
    }
    
    BMA4SInBoxMessage *message = [_messages objectAtIndex:index];
    
    if(message == nil)
    {
        NSString *errorMessage = @"Couldn't find the message to mark";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(MessageNotExists)];
        reject(operationCode,errorMessage,nil);
    }
    
    [message markAsRead];
}

//Mark as Archive Accengage message
RCT_EXPORT_METHOD(
                  markMessageAsArchived:(int)index
                  Read:(bool)archived
                  callback:(RCTPromiseResolveBlock)promise
                  rejecter:(RCTPromiseRejectBlock)reject
                  ){
    if(_messages == nil)
    {
        NSString *errorMessage = @"There's no messages to mark";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(InboxMessageListNotExists)];
        reject(operationCode,errorMessage,nil);
    }
    
    if(_inbox == nil)
    {
        NSString *errorMessage = @"There's no inbox to update";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(InboxNotExists)];
        reject(operationCode,errorMessage,nil);
    }
    
    BMA4SInBoxMessage *message = [_messages objectAtIndex:index];
    
    if(message == nil)
    {
        NSString *errorMessage = @"Couldn't find the message to mark";
        NSString *operationCode = [NSString stringWithFormat:@"%@",@(MessageNotExists)];
        reject(operationCode,errorMessage,nil);
    }
    
    [message archive];
}

#pragma mark - Device info

RCT_EXPORT_METHOD(
                  updateDeviceInfo:(NSDictionary *)object
                  ) {
    if (!object || object.count == 0) {
        NSLog(@"No fields were added");
        return;
    }
    
    [Accengage updateDeviceInfo:object];
}

#pragma mark - Clear Messages

RCT_EXPORT_METHOD(
        clearMessages
                ) {
    _messages = nil;
    _loadedMessages = nil;
    _inbox = nil;
}

@end

