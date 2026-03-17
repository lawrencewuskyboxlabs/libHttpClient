// Copyright (c) Microsoft Corporation
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#pragma once
#import <Foundation/Foundation.h>

@interface SessionDelegate : NSObject<NSURLSessionTaskDelegate, NSURLSessionDelegate, NSURLSessionDataDelegate>

+ (SessionDelegate*) sessionDelegateWithCallHandleRetriever:(HCCallHandle(^)(uint32_t sessionTimeout, NSUInteger taskIdentifier)) callRetriever andCompletionHandler:(void(^)(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse* response, NSError* error)) completion;
+ (void) reportProgress:(HCCallHandle)call progressReportFunction:(HCHttpCallProgressReportFunction)progressReportFunction minimumInterval:(size_t)minimumInterval current:(size_t)current total:(size_t)total progressReportCallbackContext:(void*)progressReportCallbackContext lastProgressReport:(std::chrono::steady_clock::time_point*)lastProgressReport;
@end
