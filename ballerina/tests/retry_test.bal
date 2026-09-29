// Copyright (c) 2026, dasunorg
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/test;

type RetryCase record {|
    int? status;
    string? errorCode;
    boolean retryable;
|};

@test:Config
function testIsRetryableErrorTruthTable() {
    RetryCase[] cases = [
        // Local pre-flight failures: a missing credential source or a signing failure is
        // deterministic, so retrying it just delays the same error.
        {status: (), errorCode: LOCAL_FAILURE_ERROR_CODE, retryable: false},
        {status: 500, errorCode: LOCAL_FAILURE_ERROR_CODE, retryable: false},
        {status: 429, errorCode: LOCAL_FAILURE_ERROR_CODE, retryable: false},

        // AWS-side transient failures.
        {status: 429, errorCode: "ThrottledException", retryable: true},
        {status: 400, errorCode: "ThrottlingException", retryable: true},
        {status: 409, errorCode: "RetryableConflictException", retryable: true},
        {status: 500, errorCode: "ServiceException", retryable: true},
        {status: 503, errorCode: "ServiceUnavailable", retryable: true},
        {status: 500, errorCode: "InternalFailure", retryable: true},

        // AWS-side permanent failures.
        {status: 400, errorCode: "ValidationException", retryable: false},
        {status: 403, errorCode: "AccessDeniedException", retryable: false},
        {status: 404, errorCode: "ResourceNotFoundException", retryable: false},
        {status: 402, errorCode: "ServiceQuotaExceededException", retryable: false},
        {status: 409, errorCode: "ConflictException", retryable: false},

        // Status-only classification, for responses without an `x-amzn-errortype` header.
        {status: 429, errorCode: (), retryable: true},
        {status: 500, errorCode: (), retryable: true},
        {status: 503, errorCode: (), retryable: true},
        {status: 400, errorCode: (), retryable: false},
        {status: 403, errorCode: (), retryable: false},
        {status: 404, errorCode: (), retryable: false},
        {status: 402, errorCode: (), retryable: false},

        // No response and no error code at all: a transport failure, which a retry can paper over.
        {status: (), errorCode: (), retryable: true}
    ];

    foreach RetryCase c in cases {
        test:assertEquals(isRetryableError(c.status, c.errorCode), c.retryable,
                string `status=${c.status.toString()} errorCode=${c.errorCode.toString()}`);
    }
}

@test:Config
function testBackoffDelayStaysWithinTheJitterWindow() {
    decimal[] caps = [1, 2, 4, 8, 16, 20, 20, 20];
    foreach int attempt in 0 ..< caps.length() {
        decimal cap = caps[attempt];
        foreach int _ in 0 ..< 20 {
            decimal delay = backoffDelay(attempt);
            test:assertTrue(delay >= 0d && delay <= cap,
                    string `backoffDelay(${attempt}) = ${delay} outside [0, ${cap}]`);
        }
    }
    test:assertTrue(backoffDelay(100) <= MAX_BACKOFF_SECONDS, "the backoff cap must hold for any attempt");
}
