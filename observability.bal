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

import ballerina/log;
import ballerina/observe;
import ballerinax/aws;

// `ballerina/ai` 1.15.0 has no memory span (`ai.observe` covers LLM/tool/embedding/knowledge-base
// spans only, and its span tagging is module-private besides), so a genuine trace span for memory
// operations is not implementable from outside that module - see the package's design notes,
// which also track this as an upstream ask. In the meantime, `ai:Agent` calls `Memory.update` in
// fire-and-forget style and logs failures only at debug level (see `ballerina/ai`'s
// `updateMemory`), effectively swallowing them from an operator's perspective. Every AgentCore
// call failure is therefore logged here at `WARN`, with whatever AWS request id is available, so
// operators have somewhere to look; when a span *is* already active in the caller's context
// (e.g. this code runs inside an HTTP-served agent), the request id is best-effort attached to it
// too via `observe:addTag`.
isolated function logAgentCoreFailure(string operation, string sessionId, Error err) {
    aws:ErrorDetails details = err.detail();
    log:printWarn(string `AgentCore ${operation} failed for session '${sessionId}'.`, err,
        errorCode = details?.errorCode, httpStatusCode = details?.httpStatusCode, requestId = details?.requestId);

    string? requestId = details?.requestId;
    if requestId is string {
        // Best-effort: `observe:addTag` fails when no span is active in the current context,
        // which is the common case for a plain (non-HTTP-served) agent run. That failure is not
        // itself worth logging - the WARN above already recorded the request id.
        error? tagResult = observe:addTag("aws.bedrockagentcore.requestId", requestId);
        if tagResult is error {
            // No active span in the current context; the WARN log above already recorded the
            // request id, so there is nothing further to do here.
        }
    }
}
