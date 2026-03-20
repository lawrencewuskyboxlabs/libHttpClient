// Copyright (c) Microsoft Corporation
// Licensed under the MIT license. See LICENSE file in the project root for full license information.

#include "pch.h"
#import <Foundation/Foundation.h>
#include <httpClient/httpProvider.h>
#include "http_apple.h"
#include "request_body_stream.h"
#include "session_delegate.h"
#include <shared_mutex>

NAMESPACE_XBOX_HTTP_CLIENT_BEGIN

struct AppleHttpTaskContext
{
    HCCallHandle m_call; // non owning
    XAsyncBlock* m_asyncBlock; // non owning
};

struct AppleHttpSession
{
    NSURLSession* m_session;
    std::unordered_map<NSUInteger, AppleHttpTaskContext> m_httpTaskContexts;
};

class AppleHttpSessionManager : public std::enable_shared_from_this<AppleHttpSessionManager>
{
public:
    HRESULT InitiateRequest(
        HCCallHandle call,
        XAsyncBlock *async
    ) noexcept;
    
private:
    std::shared_mutex m_httpSessionsMutex;
    std::unordered_map<uint32_t, AppleHttpSession> m_httpSessions;
    
    void StartTaskOnSession(HCCallHandle call, XAsyncBlock* asyncBlock, NSURLRequest* request);
    HCCallHandle GetCallHandle(uint32_t sessionTimeout, NSUInteger taskIdentifier);
    void CompletionHandler(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse* response, NSError* error);
};

void AppleHttpSessionManager::StartTaskOnSession(HCCallHandle call, XAsyncBlock* asyncBlock, NSURLRequest* request)
{
    uint32_t timeoutInSeconds = 0;
    if (FAILED(HCHttpCallRequestGetTimeout(call, &timeoutInSeconds)))
    {
        // default to 60 to match other default ios behaviour
        timeoutInSeconds = 60;
    }
    
    {
        std::unique_lock<std::shared_mutex> uniqueLock(m_httpSessionsMutex);
        
        NSURLSession* session = nil;
        auto httpSessionIter = m_httpSessions.find(timeoutInSeconds);
        if (httpSessionIter != m_httpSessions.end())
        {
            session = httpSessionIter->second.m_session;
        }
        else {
            NSURLSessionConfiguration* configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            [configuration setTimeoutIntervalForRequest:(NSTimeInterval)timeoutInSeconds];
            [configuration setTimeoutIntervalForResource:(NSTimeInterval)timeoutInSeconds];
            
            std::weak_ptr<AppleHttpSessionManager> weak_this = shared_from_this();
            
            SessionDelegate* delegate = [SessionDelegate sessionDelegateWithCallHandleRetriever:^HCCallHandle(uint32_t sessionTimeout, NSUInteger taskIdentifier) {
                if (auto me = weak_this.lock())
                {
                    return me->GetCallHandle(sessionTimeout, taskIdentifier);
                }
                else {
                    return nullptr;
                }
            } andCompletionHandler:^(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse *response, NSError *error) {
                if (auto me = weak_this.lock())
                {
                    me->CompletionHandler(sessionTimeout, taskIdentifier, response, error);
                }
            }];
            
            session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:nil];
            httpSessionIter = m_httpSessions.emplace(timeoutInSeconds, AppleHttpSession{ .m_session = session }).first;
        }
        
        NSURLSessionTask* sessionTask = [session dataTaskWithRequest:request];
        NSUInteger taskIdentifier = [sessionTask taskIdentifier];
        
        if (httpSessionIter->second.m_httpTaskContexts.count(taskIdentifier) > 0)
        {
            HC_TRACE_ERROR(HTTPCLIENT, "Shared session with timeout %u already has task with identifier %u", timeoutInSeconds, taskIdentifier);
            [sessionTask cancel];
        }
        else
        {
            httpSessionIter->second.m_httpTaskContexts.emplace(taskIdentifier, AppleHttpTaskContext{ .m_call = call, .m_asyncBlock = asyncBlock });
            [sessionTask resume];
        }
    }
}

HCCallHandle AppleHttpSessionManager::GetCallHandle(uint32_t sessionTimeout, NSUInteger taskIdentifier)
{
    std::shared_lock<std::shared_mutex> sharedLock(m_httpSessionsMutex);
    
    auto httpSessionIter = m_httpSessions.find(sessionTimeout);
    if (httpSessionIter == m_httpSessions.end())
    {
        HC_TRACE_ERROR(HTTPCLIENT, "No existing session with timeout %u", sessionTimeout);
        return nullptr;
    }
    
    auto taskContextIter = httpSessionIter->second.m_httpTaskContexts.find(taskIdentifier);
    if (taskContextIter == httpSessionIter->second.m_httpTaskContexts.end())
    {
        HC_TRACE_ERROR(HTTPCLIENT, "No existing task context with identifier %u", taskIdentifier);
        return nullptr;
    }
    
    return taskContextIter->second.m_call;
}

void AppleHttpSessionManager::CompletionHandler(uint32_t sessionTimeout, NSUInteger taskIdentifier, NSURLResponse* response, NSError* error)
{
    AppleHttpTaskContext taskContext;
    {
        std::unique_lock<std::shared_mutex> uniqueLock(m_httpSessionsMutex);
        
        auto httpSessionIter = m_httpSessions.find(sessionTimeout);
        if (httpSessionIter == m_httpSessions.end())
        {
            HC_TRACE_ERROR(HTTPCLIENT, "No existing session with timeout %u", sessionTimeout);
            return;
        }
        
        auto taskContextIter = httpSessionIter->second.m_httpTaskContexts.find(taskIdentifier);
        if (taskContextIter == httpSessionIter->second.m_httpTaskContexts.end())
        {
            HC_TRACE_ERROR(HTTPCLIENT, "No existing task context with identifier %u", taskIdentifier);
            return;
        }
        
        taskContext = taskContextIter->second;
        
        if (httpSessionIter->second.m_httpTaskContexts.size() > 1)
        {
            httpSessionIter->second.m_httpTaskContexts.erase(taskContextIter);
        }
        else
        {
            [httpSessionIter->second.m_session finishTasksAndInvalidate];
            m_httpSessions.erase(httpSessionIter);
        }
    }
    
    if (error)
    {
        const char *cstr = [[error description] UTF8String];
        HC_TRACE_ERROR(HTTPCLIENT, "Task identifier %u ran into Error description %s", taskIdentifier, cstr);
        
        uint32_t errorCode = static_cast<uint32_t>([error code]);
        HC_TRACE_ERROR(HTTPCLIENT, "HCHttpCallPerform [ID %u] error from NSURLRequest code: %u", HCHttpCallGetId(taskContext.m_call), errorCode);
        HRESULT errorResult = E_FAIL;
        if ([[error domain] isEqualToString:NSURLErrorDomain] && [error code] == NSURLErrorNotConnectedToInternet)
        {
            errorResult = E_HC_NO_NETWORK;
        }

        HCHttpCallResponseSetNetworkErrorCode(taskContext.m_call, errorResult, errorCode);
        XAsyncComplete(taskContext.m_asyncBlock, errorResult, 0);
        return;
    }

    assert([response isKindOfClass:[NSHTTPURLResponse class]]);
    NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;

    uint32_t statusCode = static_cast<uint32_t>([httpResponse statusCode]);

    HCHttpCallResponseSetStatusCode(taskContext.m_call, statusCode);

    NSDictionary* headers = [httpResponse allHeaderFields];
    for (NSString* key in headers)
    {
        NSString* value = headers[key];

        char const* keyCString = [key cStringUsingEncoding:NSUTF8StringEncoding];
        char const* valueCString = [value cStringUsingEncoding:NSUTF8StringEncoding];
        HCHttpCallResponseSetHeader(taskContext.m_call, keyCString, valueCString);
    }
    
    HCTraceSetTraceToDebugger(true);
    HCSettingsSetTraceLevel(HCTraceLevel::Verbose);
    HC_TRACE_ERROR(HTTPCLIENT, "AppleHttp completion handler %s", taskContext.m_call->url.c_str());

    XAsyncComplete(taskContext.m_asyncBlock, S_OK, 0);
}

HRESULT AppleHttpSessionManager::InitiateRequest(
    _In_ HCCallHandle call,
    _Inout_ XAsyncBlock* asyncBlock
) noexcept
{
    char const* urlCString = nullptr;
    char const* methodCString = nullptr;
    if (FAILED(HCHttpCallRequestGetUrl(call, &methodCString, &urlCString)))
    {
        HCHttpCallResponseSetNetworkErrorCode(call, E_FAIL, 0);
        XAsyncComplete(asyncBlock, E_FAIL, 0);
        return S_OK;
    }

    NSString* urlString = [[NSString alloc] initWithUTF8String:urlCString];
    NSURL* url = [NSURL URLWithString:urlString];

    NSString* methodString = [[NSString alloc] initWithUTF8String:methodCString];

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:methodString];

    uint32_t numHeaders = 0;
    if (FAILED(HCHttpCallRequestGetNumHeaders(call, &numHeaders)))
    {
        HCHttpCallResponseSetNetworkErrorCode(call, E_FAIL, 0);
        XAsyncComplete(asyncBlock, E_FAIL, 0);
        return S_OK;
    }

    for (uint32_t i = 0; i<numHeaders; ++i)
    {
        char const* headerName;
        char const* headerValue;
        if (SUCCEEDED(HCHttpCallRequestGetHeaderAtIndex(call, i, &headerName, &headerValue)))
        {
            NSString* headerNameString = [[NSString alloc] initWithUTF8String:headerName];
            NSString* headerValueString = [[NSString alloc] initWithUTF8String:headerValue];

            [request addValue:headerValueString forHTTPHeaderField:headerNameString];
        }
    }

    HCHttpCallRequestBodyReadFunction readFunction = nullptr;
    size_t requestBodySize = 0;
    void* context = nullptr;
    if (FAILED(HCHttpCallRequestGetRequestBodyReadFunction(call, &readFunction, &requestBodySize, &context))
        || readFunction == nullptr)
    {
        HCHttpCallResponseSetNetworkErrorCode(call, E_FAIL, 0);
        XAsyncComplete(asyncBlock, E_FAIL, 0);
        return S_OK;
    }

    if (requestBodySize > 0)
    {
        [request setHTTPBodyStream:[RequestBodyStream requestBodyStreamWithHCCallHandle:call]];
        [request addValue:[NSString stringWithFormat:@"%zu", requestBodySize] forHTTPHeaderField:@"Content-Length"];
    }
    
    StartTaskOnSession(call, asyncBlock, request);
    
    HCTraceSetTraceToDebugger(true);
    HCSettingsSetTraceLevel(HCTraceLevel::Verbose);
    HC_TRACE_ERROR(HTTPCLIENT, "AppleHttp request initiated %s", call->url.c_str());
    
    return S_OK;
}

AppleHttpProvider::AppleHttpProvider() : m_httpSessionManager(std::make_shared<AppleHttpSessionManager>())
{
}

AppleHttpProvider::~AppleHttpProvider() = default;

HRESULT AppleHttpProvider::PerformAsync(
    _In_ HCCallHandle call,
    _Inout_ XAsyncBlock* asyncBlock
) noexcept
{
    return m_httpSessionManager->InitiateRequest(call, asyncBlock);
}

NAMESPACE_XBOX_HTTP_CLIENT_END
