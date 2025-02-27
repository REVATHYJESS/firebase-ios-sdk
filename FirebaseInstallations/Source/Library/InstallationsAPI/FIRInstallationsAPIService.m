/*
 * Copyright 2019 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FIRInstallationsAPIService.h"

#import <FirebaseInstallations/FIRInstallationsVersion.h>

#if __has_include(<FBLPromises/FBLPromises.h>)
#import <FBLPromises/FBLPromises.h>
#else
#import "FBLPromises.h"
#endif

#import "FIRInstallationsErrorUtil.h"
#import "FIRInstallationsItem+RegisterInstallationAPI.h"
#import "FIRInstallationsLogger.h"

NSString *const kFIRInstallationsAPIBaseURL = @"https://firebaseinstallations.googleapis.com";
NSString *const kFIRInstallationsAPIKey = @"X-Goog-Api-Key";

NS_ASSUME_NONNULL_BEGIN

@interface FIRInstallationsURLSessionResponse : NSObject
@property(nonatomic) NSHTTPURLResponse *HTTPResponse;
@property(nonatomic) NSData *data;

- (instancetype)initWithResponse:(NSHTTPURLResponse *)response data:(nullable NSData *)data;
@end

@implementation FIRInstallationsURLSessionResponse

- (instancetype)initWithResponse:(NSHTTPURLResponse *)response data:(nullable NSData *)data {
  self = [super init];
  if (self) {
    _HTTPResponse = response;
    _data = data ?: [NSData data];
  }
  return self;
}

@end

@interface FIRInstallationsAPIService ()
@property(nonatomic, readonly) NSURLSession *URLSession;
@end

NS_ASSUME_NONNULL_END

@implementation FIRInstallationsAPIService

- (instancetype)initWithAPIKey:(NSString *)APIKey projectID:(NSString *)projectID {
  NSURLSession *URLSession = [NSURLSession
      sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
  return [self initWithURLSession:URLSession APIKey:APIKey projectID:projectID];
}

/// The initializer for tests.
- (instancetype)initWithURLSession:(NSURLSession *)URLSession
                            APIKey:(NSString *)APIKey
                         projectID:(NSString *)projectID {
  self = [super init];
  if (self) {
    _URLSession = URLSession;
    _APIKey = [APIKey copy];
    _projectID = [projectID copy];
  }
  return self;
}

#pragma mark - Public

- (FBLPromise<FIRInstallationsItem *> *)registerInstallation:(FIRInstallationsItem *)installation {
  NSURLRequest *request = [self registerRequestWithInstallation:installation];
  return [self sendURLRequest:request].then(
      ^id _Nullable(FIRInstallationsURLSessionResponse *response) {
        return [self registeredInstallationWithInstallation:installation serverResponse:response];
      });
}

- (FBLPromise<FIRInstallationsItem *> *)refreshAuthTokenForInstallation:
    (FIRInstallationsItem *)installation {
  NSURLRequest *request = [self authTokenRequestWithInstallation:installation];
  return [self sendURLRequest:request]
      .then(^FBLPromise<FIRInstallationsStoredAuthToken *> *(
          FIRInstallationsURLSessionResponse *response) {
        return [self authTokenWithServerResponse:response];
      })
      .then(^FIRInstallationsItem *(FIRInstallationsStoredAuthToken *authToken) {
        FIRInstallationsItem *updatedInstallation = [installation copy];
        updatedInstallation.authToken = authToken;
        return updatedInstallation;
      });
}

- (FBLPromise<FIRInstallationsItem *> *)deleteInstallation:(FIRInstallationsItem *)installation {
  NSURLRequest *request = [self deleteInstallationRequestWithInstallation:installation];
  return [[self sendURLRequest:request]
      then:^id _Nullable(FIRInstallationsURLSessionResponse *_Nullable value) {
        // Return the original installation on success.
        return installation;
      }];
}

#pragma mark - Register Installation

- (NSURLRequest *)registerRequestWithInstallation:(FIRInstallationsItem *)installation {
  NSString *URLString = [NSString stringWithFormat:@"%@/v1/projects/%@/installations/",
                                                   kFIRInstallationsAPIBaseURL, self.projectID];
  NSURL *URL = [NSURL URLWithString:URLString];

  NSDictionary *bodyDict = @{
    @"fid" : installation.firebaseInstallationID,
    @"authVersion" : @"FIS_v2",
    @"appId" : installation.appID,
    @"sdkVersion" : [self SDKVersion]
  };

  return [self requestWithURL:URL HTTPMethod:@"POST" bodyDict:bodyDict refreshToken:nil];
}

- (FBLPromise<FIRInstallationsItem *> *)
    registeredInstallationWithInstallation:(FIRInstallationsItem *)installation
                            serverResponse:(FIRInstallationsURLSessionResponse *)response {
  return [FBLPromise do:^id {
    FIRLogDebug(kFIRLoggerInstallations, kFIRInstallationsMessageCodeParsingAPIResponse,
                @"Parsing server response for %@.", response.HTTPResponse.URL);
    NSError *error;
    FIRInstallationsItem *registeredInstallation =
        [installation registeredInstallationWithJSONData:response.data
                                                    date:[NSDate date]
                                                   error:&error];
    if (registeredInstallation == nil) {
      FIRLogDebug(kFIRLoggerInstallations,
                  kFIRInstallationsMessageCodeAPIResponseParsingInstallationFailed,
                  @"Failed to parse FIRInstallationsItem: %@.", error);
      return error;
    }

    FIRLogDebug(kFIRLoggerInstallations,
                kFIRInstallationsMessageCodeAPIResponseParsingInstallationSucceed,
                @"FIRInstallationsItem parsed successfully.");
    return registeredInstallation;
  }];
}

#pragma mark - Auth token

- (NSURLRequest *)authTokenRequestWithInstallation:(FIRInstallationsItem *)installation {
  NSString *URLString =
      [NSString stringWithFormat:@"%@/v1/projects/%@/installations/%@/authTokens:generate",
                                 kFIRInstallationsAPIBaseURL, self.projectID,
                                 installation.firebaseInstallationID];
  NSURL *URL = [NSURL URLWithString:URLString];

  NSDictionary *bodyDict = @{@"installation" : @{@"sdkVersion" : [self SDKVersion]}};
  return [self requestWithURL:URL
                   HTTPMethod:@"POST"
                     bodyDict:bodyDict
                 refreshToken:installation.refreshToken];
}

- (FBLPromise<FIRInstallationsStoredAuthToken *> *)authTokenWithServerResponse:
    (FIRInstallationsURLSessionResponse *)response {
  return [FBLPromise do:^id {
    FIRLogDebug(kFIRLoggerInstallations, kFIRInstallationsMessageCodeParsingAPIResponse,
                @"Parsing server response for %@.", response.HTTPResponse.URL);
    NSError *error;
    FIRInstallationsStoredAuthToken *token =
        [FIRInstallationsItem authTokenWithGenerateTokenAPIJSONData:response.data
                                                               date:[NSDate date]
                                                              error:&error];
    if (token == nil) {
      FIRLogDebug(kFIRLoggerInstallations,
                  kFIRInstallationsMessageCodeAPIResponseParsingAuthTokenFailed,
                  @"Failed to parse FIRInstallationsStoredAuthToken: %@.", error);
      return error;
    }

    FIRLogDebug(kFIRLoggerInstallations,
                kFIRInstallationsMessageCodeAPIResponseParsingAuthTokenSucceed,
                @"FIRInstallationsStoredAuthToken parsed successfully.");
    return token;
  }];
}

#pragma mark - Delete Installation

- (NSURLRequest *)deleteInstallationRequestWithInstallation:(FIRInstallationsItem *)installation {
  NSString *URLString = [NSString stringWithFormat:@"%@/v1/projects/%@/installations/%@/",
                                                   kFIRInstallationsAPIBaseURL, self.projectID,
                                                   installation.firebaseInstallationID];
  NSURL *URL = [NSURL URLWithString:URLString];

  return [self requestWithURL:URL
                   HTTPMethod:@"DELETE"
                     bodyDict:@{}
                 refreshToken:installation.refreshToken];
}

#pragma mark - URL Request
- (NSURLRequest *)requestWithURL:(NSURL *)requestURL
                      HTTPMethod:(NSString *)HTTPMethod
                        bodyDict:(NSDictionary *)bodyDict
                    refreshToken:(nullable NSString *)refreshToken {
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
  request.HTTPMethod = HTTPMethod;
  [request addValue:self.APIKey forHTTPHeaderField:kFIRInstallationsAPIKey];
  [self setJSONHTTPBody:bodyDict forRequest:request];
  if (refreshToken) {
    NSString *authHeader = [NSString stringWithFormat:@"FIS_v2 %@", refreshToken];
    [request setValue:authHeader forHTTPHeaderField:@"Authorization"];
  }
  return [request copy];
}

- (FBLPromise<FIRInstallationsURLSessionResponse *> *)URLRequestPromise:(NSURLRequest *)request {
  return [[FBLPromise async:^(FBLPromiseFulfillBlock fulfill, FBLPromiseRejectBlock reject) {
    FIRLogDebug(kFIRLoggerInstallations, kFIRInstallationsMessageCodeSendAPIRequest,
                @"Sending request: %@, body:%@, headers: %@.", request,
                [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding],
                request.allHTTPHeaderFields);
    [[self.URLSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *_Nullable data, NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            if (error) {
              FIRLogDebug(kFIRLoggerInstallations,
                          kFIRInstallationsMessageCodeAPIRequestNetworkError,
                          @"Request failed: %@, error: %@.", request, error);
              reject(error);
            } else {
              FIRLogDebug(kFIRLoggerInstallations, kFIRInstallationsMessageCodeAPIRequestResponse,
                          @"Request response received: %@, error: %@, body: %@.", request, error,
                          [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
              fulfill([[FIRInstallationsURLSessionResponse alloc]
                  initWithResponse:(NSHTTPURLResponse *)response
                              data:data]);
            }
          }] resume];
  }] then:^id _Nullable(FIRInstallationsURLSessionResponse *response) {
    return [self validateHTTPResponseStatusCode:response];
  }];
}

- (FBLPromise<FIRInstallationsURLSessionResponse *> *)validateHTTPResponseStatusCode:
    (FIRInstallationsURLSessionResponse *)response {
  NSInteger statusCode = response.HTTPResponse.statusCode;
  return [FBLPromise do:^id _Nullable {
    if (statusCode < 200 || statusCode >= 300) {
      FIRLogDebug(kFIRLoggerInstallations, kFIRInstallationsMessageCodeUnexpectedAPIRequestResponse,
                  @"Unexpected API response: %@, body: %@.", response.HTTPResponse,
                  [[NSString alloc] initWithData:response.data encoding:NSUTF8StringEncoding]);
      return [FIRInstallationsErrorUtil APIErrorWithHTTPResponse:response.HTTPResponse
                                                            data:response.data];
    }
    return response;
  }];
}

- (FBLPromise<FIRInstallationsURLSessionResponse *> *)sendURLRequest:(NSURLRequest *)request {
  return [FBLPromise attempts:1
      delay:1
      condition:^BOOL(NSInteger remainingAttempts, NSError *_Nonnull error) {
        return [FIRInstallationsErrorUtil isAPIError:error withHTTPCode:500];
      }
      retry:^id _Nullable {
        return [self URLRequestPromise:request];
      }];
}

- (NSString *)SDKVersion {
  return [NSString stringWithFormat:@"i:%s", FIRInstallationsVersionStr];
}

#pragma mark - JSON

- (void)setJSONHTTPBody:(NSDictionary<NSString *, id> *)body
             forRequest:(NSMutableURLRequest *)request {
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  NSError *error;
  NSData *JSONData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&error];
  if (JSONData == nil) {
    // TODO: Log or return an error.
  }
  request.HTTPBody = JSONData;
}

@end
