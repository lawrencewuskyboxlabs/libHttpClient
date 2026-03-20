// Copyright (c) Microsoft Corporation
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include "pch.h"
#include <httpClient/httpProvider.h>
#import "session_delegate.h"
#include <shared_mutex>

struct TaskContext
{
    HCCallHandle _call; // non owning
    long long _downloadSize;
};

@implementation SessionDelegate
{
    HCCallHandle(^_callHandleRetriever)(uint32_t sessionTimeout, NSUInteger taskIdentifier);
    void(^_completionHandler)(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse* response, NSError* error);
    
    std::shared_mutex _taskContextsMutex;
    std::unordered_map<NSUInteger, TaskContext> _taskContexts;
}

+ (SessionDelegate*) sessionDelegateWithCallHandleRetriever:(HCCallHandle(^)(uint32_t sessionTimeout, NSUInteger taskIdentifier)) callRetriever andCompletionHandler:(void(^)(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse* response, NSError* error)) completionHandler
{
    return [[SessionDelegate alloc] initWithCallHandleRetriever: callRetriever andCompletionHandler:completionHandler];
}

+ (void) reportProgress:(HCCallHandle)call progressReportFunction:(HCHttpCallProgressReportFunction)progressReportFunction minimumInterval:(size_t)minimumInterval current:(size_t)current total:(size_t)total progressReportCallbackContext:(void*)progressReportCallbackContext lastProgressReport:(std::chrono::steady_clock::time_point*)lastProgressReport
{
    if (progressReportFunction != nullptr)
    {
        long minimumProgressReportIntervalInMs = static_cast<long>(minimumInterval * 1000);

        std::chrono::steady_clock::time_point now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - *lastProgressReport).count();

        if (elapsed >= minimumProgressReportIntervalInMs)
        {
            HRESULT hr = progressReportFunction(call, (int)current, (int)total, progressReportCallbackContext);
            if (FAILED(hr))
            {
                HC_TRACE_ERROR_HR(HTTPCLIENT, hr, "CurlEasyRequest::ReportProgress: something went wrong after invoking the progress callback function.");
            }

            *lastProgressReport = now;
        }
    }
}

- (instancetype) initWithCallHandleRetriever:(HCCallHandle(^)(uint32_t sessionTimeout, NSUInteger taskIdentifier)) callRetriever andCompletionHandler:(void(^)(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse* response, NSError* error)) completionHandler
{
    if (self = [super init])
    {
        _callHandleRetriever = callRetriever;
        _completionHandler = completionHandler;
        return self;
    }
    return nil;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error
{
    {
        std::unique_lock<std::shared_mutex> uniqueLock(_taskContextsMutex);
        _taskContexts.erase([task taskIdentifier]);
        
        HC_TRACE_ERROR(HTTPCLIENT, "Task context erased for identifier %u", [task taskIdentifier]);
    }
    
    _completionHandler([[session configuration] timeoutIntervalForRequest], [task taskIdentifier], [task response], error);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data
{
    HCHttpCallResponseBodyWriteFunction writeFunction = nullptr;
    void* context = nullptr;
    
    TaskContext taskContext;
    {
        std::shared_lock<std::shared_mutex> sharedLock(_taskContextsMutex);
        auto existingTaskContext = _taskContexts.find([task taskIdentifier]);
        if (existingTaskContext == _taskContexts.end())
        {
            HC_TRACE_ERROR(HTTPCLIENT, "Task context missing for identifier %u", [task taskIdentifier]);
            [task cancel];
            return;
        }
        taskContext = existingTaskContext->second;
    }
    
    if (FAILED(HCHttpCallResponseGetResponseBodyWriteFunction(taskContext._call, &writeFunction, &context)) ||
        writeFunction == nullptr)
    {
        [task cancel];
        return;
    }

    try
    {
        __block HRESULT hr = S_OK;
        [data enumerateByteRangesUsingBlock:^(const void* bytes, NSRange byteRange, BOOL* stop) {
            hr = writeFunction(taskContext._call, static_cast<const uint8_t*>(bytes), static_cast<size_t>(byteRange.length), context);
            if (FAILED(hr))
            {
                *stop = YES;
            }
        }];

        if (FAILED(hr))
        {
            [task cancel];
            return;
        }
    }
    catch (...)
    {
        [task cancel];
        return;
    }
    
    size_t downloadMinimumProgressInterval;
    void* downloadProgressReportCallbackContext{};
    HCHttpCallProgressReportFunction downloadProgressReportFunction = nullptr;
    HRESULT hr = HCHttpCallRequestGetProgressReportFunction(taskContext._call, false, &downloadProgressReportFunction, &downloadMinimumProgressInterval, &downloadProgressReportCallbackContext);
    if (FAILED(hr))
    {
        HC_TRACE_ERROR_HR(HTTPCLIENT, hr, "CurlEasyRequest::ProgressReportCallback: failed getting Progress Report upload function");
    }

    [SessionDelegate reportProgress:taskContext._call progressReportFunction:downloadProgressReportFunction minimumInterval:taskContext._call->downloadMinimumProgressReportInterval current:taskContext._call->responseBodyBytes.size() total:taskContext._downloadSize progressReportCallbackContext: downloadProgressReportCallbackContext lastProgressReport:&taskContext._call->downloadLastProgressReport];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
    size_t uploadMinimumProgressInterval;
    void* uploadProgressReportCallbackContext{};
    HCHttpCallProgressReportFunction uploadProgressReportFunction = nullptr;
    
    HCCallHandle call;
    {
        std::shared_lock<std::shared_mutex> sharedLock(_taskContextsMutex);
        auto existingTaskContext = _taskContexts.find([task taskIdentifier]);
        if (existingTaskContext == _taskContexts.end())
        {
            HC_TRACE_ERROR(HTTPCLIENT, "Task context missing for identifier %u", [task taskIdentifier]);
            [task cancel];
            return;
        }
        call = existingTaskContext->second._call;
    }
    
    HRESULT hr = HCHttpCallRequestGetProgressReportFunction(call, true, &uploadProgressReportFunction, &uploadMinimumProgressInterval, &uploadProgressReportCallbackContext);
    if (FAILED(hr))
    {
        HC_TRACE_ERROR_HR(HTTPCLIENT, hr, "CurlEasyRequest::ProgressReportCallback: failed getting Progress Report upload function");
    }

    [SessionDelegate reportProgress:call progressReportFunction:uploadProgressReportFunction minimumInterval:call->uploadMinimumProgressReportInterval current:totalBytesSent total:totalBytesExpectedToSend progressReportCallbackContext:uploadProgressReportCallbackContext lastProgressReport:&call->uploadLastProgressReport];
    
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    completionHandler(NSURLSessionResponseAllow);
    
    HCCallHandle call = _callHandleRetriever([[session configuration] timeoutIntervalForRequest], [dataTask taskIdentifier]);
    
    {
        std::unique_lock<std::shared_mutex> uniqueLock(_taskContextsMutex);
        _taskContexts.emplace([dataTask taskIdentifier], TaskContext{ ._call = call, ._downloadSize = [response expectedContentLength]});
        
        HC_TRACE_ERROR(HTTPCLIENT, "Task context emplaced for identifier %u", [dataTask taskIdentifier]);
    }
}

@end
