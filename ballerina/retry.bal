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

import ballerina/random;

// Error codes and HTTP statuses worth retrying: throttling, retryable conflicts, and server-side
// faults. Anything else (validation, access-denied, not-found) is a client-input problem retrying
// will not fix.
final readonly & string[] RETRYABLE_ERROR_CODES = [
    "ThrottledException",
    "ThrottlingException",
    "RetryableConflictException",
    "ServiceException",
    "ServiceUnavailable",
    "InternalFailure"
];

// Marks an `Error` built before any HTTP call was attempted - credential resolution or SigV4
// signing failed locally (see `client.bal`'s `sendOnce`). These are deterministic misconfiguration
// problems (no credentials available, a malformed region, ...) that will not start succeeding a
// few seconds later, so they are excluded from the "no error code -> retryable" default below,
// unlike a genuine transport failure (connection reset, DNS blip), which keeps that default.
const string LOCAL_FAILURE_ERROR_CODE = "LocalFailure";

isolated function isRetryableError(int? httpStatusCode, string? errorCode) returns boolean {
    if errorCode == LOCAL_FAILURE_ERROR_CODE {
        return false;
    }
    if errorCode is string {
        foreach string retryableCode in RETRYABLE_ERROR_CODES {
            if errorCode == retryableCode {
                return true;
            }
        }
    }
    if httpStatusCode is int {
        return httpStatusCode == 429 || httpStatusCode >= 500;
    }
    // No response was received at all and no error code was set: a genuine transport failure
    // (connection failure, timeout) rather than a local pre-flight failure - worth a retry.
    return true;
}

// Full-jitter exponential backoff: `sleep = random(0, min(MAX, INITIAL * FACTOR^attempt))`.
// See the AWS Architecture Blog post "Exponential Backoff And Jitter" for the rationale.
isolated function backoffDelay(int attempt) returns decimal {
    decimal cap = INITIAL_BACKOFF_SECONDS;
    foreach int _ in 0 ..< attempt {
        cap *= BACKOFF_FACTOR;
        if cap >= MAX_BACKOFF_SECONDS {
            cap = MAX_BACKOFF_SECONDS;
            break;
        }
    }
    return <decimal>random:createDecimal() * cap;
}
