#import <SPTDataLoader/SPTDataLoaderService.h>

#import <SPTDataLoader/SPTCancellationTokenFactoryImplementation.h>
#import <SPTDataLoader/SPTCancellationToken.h>
#import <SPTDataLoader/SPTDataLoaderRateLimiter.h>
#import <SPTDataLoader/SPTDataLoaderResolver.h>

#import "SPTDataLoaderFactory+Private.h"
#import "SPTDataLoaderRequestOperation.h"
#import "SPTDataLoaderRequest+Private.h"
#import "SPTDataLoaderRequestResponseHandler.h"
#import "SPTDataLoaderResponse+Private.h"

@interface SPTDataLoaderService () <SPTDataLoaderRequestResponseHandlerDelegate, SPTCancellationTokenDelegate, NSURLSessionDataDelegate>

@property (nonatomic, strong) SPTDataLoaderRateLimiter *rateLimiter;
@property (nonatomic, strong) SPTDataLoaderResolver *resolver;

@property (nonatomic, strong) id<SPTCancellationTokenFactory> cancellationTokenFactory;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSOperationQueue *sessionQueue;

@end

@implementation SPTDataLoaderService

#pragma mark SPTDataLoaderService

+ (instancetype)dataLoaderServiceWithUserAgent:(NSString *)userAgent
                                   rateLimiter:(SPTDataLoaderRateLimiter *)rateLimiter
                                      resolver:(SPTDataLoaderResolver *)resolver
{
    return [[self alloc] initWithUserAgent:userAgent rateLimiter:rateLimiter resolver:resolver];
}

- (instancetype)initWithUserAgent:(NSString *)userAgent
                      rateLimiter:(SPTDataLoaderRateLimiter *)rateLimiter
                         resolver:(SPTDataLoaderResolver *)resolver
{
    const NSTimeInterval SPTDataLoaderServiceTimeoutInterval = 20.0;
    const NSUInteger SPTDataLoaderServiceMaxConcurrentOperations = 32;
    
    NSString * const SPTDataLoaderServiceUserAgentHeader = @"User-Agent";
    
    if (!(self = [super init])) {
        return nil;
    }
    
    _rateLimiter = rateLimiter;
    _resolver = resolver;
    
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = SPTDataLoaderServiceTimeoutInterval;
    configuration.timeoutIntervalForResource = SPTDataLoaderServiceTimeoutInterval;
    configuration.HTTPShouldUsePipelining = YES;
    if (userAgent) {
        configuration.HTTPAdditionalHeaders = @{ SPTDataLoaderServiceUserAgentHeader : userAgent };
    }
    
    _cancellationTokenFactory = [SPTCancellationTokenFactoryImplementation new];
    _sessionQueue = [NSOperationQueue new];
    _sessionQueue.maxConcurrentOperationCount = SPTDataLoaderServiceMaxConcurrentOperations;
    _sessionQueue.name = NSStringFromClass(self.class);
    _session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_sessionQueue];
    
    return self;
}

- (SPTDataLoaderFactory *)createDataLoaderFactoryWithAuthorisers:(NSArray *)authorisers
{
    return [SPTDataLoaderFactory dataLoaderFactoryWithRequestResponseHandlerDelegate:self authorisers:authorisers];
}

- (SPTDataLoaderRequestOperation *)operationForTask:(NSURLSessionTask *)task
{
    @synchronized(self) {
        for (SPTDataLoaderRequestOperation *operation in self.sessionQueue.operations) {
            if ([operation.task isEqual:task]) {
                return operation;
            }
        }
    }
    
    return nil;
}

- (void)performRequest:(SPTDataLoaderRequest *)request
requestResponseHandler:(id<SPTDataLoaderRequestResponseHandler>)requestResponseHandler
{
    NSString *host = [self.resolver addressForHost:request.URL.host];
    if (![host isEqualToString:request.URL.host] && host) {
        [request addValue:request.URL.host forHeader:SPTDataLoaderRequestHostHeader];
        NSURLComponents *requestComponents = [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:nil];
        requestComponents.host = host;
        request.URL = requestComponents.URL;
    }
    
    NSURLRequest *urlRequest = request.urlRequest;
    NSURLSessionTask *task = [self.session dataTaskWithRequest:urlRequest];
    SPTDataLoaderRequestOperation *operation = [SPTDataLoaderRequestOperation dataLoaderRequestOperationWithRequest:request
                                                                                                               task:task
                                                                                             requestResponseHandler:requestResponseHandler
                                                                                                        rateLimiter:self.rateLimiter];
    @synchronized(self) {
        [self.sessionQueue addOperation:operation];
    }
}

#pragma mark SPTDataLoaderRequestResponseHandlerDelegate

- (id<SPTCancellationToken>)requestResponseHandler:(id<SPTDataLoaderRequestResponseHandler>)requestResponseHandler
                                    performRequest:(SPTDataLoaderRequest *)request
{
    request.cancellationToken = [self.cancellationTokenFactory createCancellationTokenWithDelegate:self];
    
    if ([requestResponseHandler respondsToSelector:@selector(shouldAuthoriseRequest:)]) {
        if ([requestResponseHandler shouldAuthoriseRequest:request]) {
            if ([requestResponseHandler respondsToSelector:@selector(authoriseRequest:)]) {
                [requestResponseHandler authoriseRequest:request];
                return request.cancellationToken;
            }
        }
    }
    
    [self performRequest:request requestResponseHandler:requestResponseHandler];
    return request.cancellationToken;
}

- (void)requestResponseHandler:(id<SPTDataLoaderRequestResponseHandler>)requestResponseHandler
             authorisedRequest:(SPTDataLoaderRequest *)request
{
    [self performRequest:request requestResponseHandler:requestResponseHandler];
}

- (void)requestResponseHandler:(id<SPTDataLoaderRequestResponseHandler>)requestResponseHandler
      failedToAuthoriseRequest:(SPTDataLoaderRequest *)request
                         error:(NSError *)error
{
    SPTDataLoaderResponse *response = [SPTDataLoaderResponse dataLoaderResponseWithRequest:request response:nil];
    response.error = error;
    [requestResponseHandler failedResponse:response];
}

#pragma mark SPTCancellationTokenDelegate

- (void)cancellationTokenDidCancel:(id<SPTCancellationToken>)cancellationToken
{
    @synchronized(self) {
        for (SPTDataLoaderRequestOperation *operation in self.sessionQueue.operations) {
            if ([operation.request.cancellationToken isEqual:cancellationToken]) {
                [operation cancel];
                break;
            }
        }
    }
}

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    SPTDataLoaderRequestOperation *operation = [self operationForTask:dataTask];
    if (completionHandler) {
        completionHandler([operation receiveResponse:response]);
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    // This is highly unusual
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    SPTDataLoaderRequestOperation *operation = [self operationForTask:dataTask];
    [operation receiveData:data];
}

#pragma mark NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    SPTDataLoaderRequestOperation *operation = [self operationForTask:task];
    [operation completeWithError:error];
}

@end
