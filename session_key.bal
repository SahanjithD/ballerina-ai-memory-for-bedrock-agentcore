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

import ballerina/crypto;
import ballerina/lang.regexp;
import ballerina/log;

// AWS's own `actorId` pattern allows `/` and `:`. This module still refuses to pass them through
// unsanitized: `actorId` is a URI *path segment* in `ListEvents`/`DeleteEvent`
// (`/memories/{memoryId}/actor/{actorId}/sessions/{sessionId}`), and a raw `/` inside a value
// meant to be one path segment would split into an extra route segment, breaking the request's
// routing outright. A raw `:` is a narrower but still real hazard: `aws.auth`'s SigV4 signer
// percent-encodes `:` (as `%3A`) when it canonicalizes the path, but the id is sent on the wire
// unencoded - a mismatch between what was signed and what was sent, failing signature validation.
// `sessionId`'s own AWS pattern excludes `/` and `:` outright, so it gets the same treatment here
// for uniformity. The safe charset below is intentionally a strict subset of what AWS allows for
// either field.
final regexp:RegExp & readonly SAFE_ID_PATTERN = re `^[a-zA-Z0-9][a-zA-Z0-9_-]*$`;

const int MAX_ACTOR_ID_LENGTH = 255;
const int MAX_SESSION_ID_LENGTH = 100;

// The sanitized form must be produced deterministically and applied identically to every
// AgentCore call for a given raw id (`CreateEvent`'s body *and* `ListEvents`/`DeleteEvent`'s
// path), so that events written under a sanitized id are also found and deleted under it.
isolated function sanitizeId(string raw, int maxLength) returns string {
    if SAFE_ID_PATTERN.isFullMatch(raw) && raw.length() <= maxLength {
        return raw;
    }
    byte[] digest = crypto:hashSha256(raw.toBytes());
    return "h-" + digest.toBase16();
}

isolated function sanitizeActorId(string raw) returns string => logIfSanitized("actorId", raw, sanitizeId(raw, MAX_ACTOR_ID_LENGTH));

isolated function sanitizeSessionId(string raw) returns string =>
    logIfSanitized("sessionId", raw, sanitizeId(raw, MAX_SESSION_ID_LENGTH));

// A raw id that gets hashed is stored/looked-up under a value that does not appear anywhere in
// the AWS console or another SDK's view of the same events - worth a one-time-per-call WARN so an
// operator debugging "where did my session go" has a lead, rather than discovering this only by
// reading this file.
isolated function logIfSanitized(string idKind, string raw, string sanitized) returns string {
    if raw != sanitized {
        log:printWarn(string `AgentCore ${idKind} contains characters unsafe for a URI path segment ` +
            "and was replaced with a deterministic hash for all AgentCore calls.",
            raw = raw, sanitized = sanitized);
    }
    return sanitized;
}

# Resolves the AgentCore `[actorId, sessionId]` pair to use for the given `ai:Memory` session key.
#
# + config - The session-key resolution strategy
# + sessionId - The session key `ai:Memory` was given
# + return - `[actorId, sessionId]`, both already sanitized for safe use in a URI path segment and
# in AgentCore's own id patterns, or an `Error` if `sessionId` cannot be resolved under `config`
isolated function resolveSessionKey(SessionKeyConfig config, string sessionId) returns [string, string]|Error {
    [string, string] keys = check splitSessionKey(config, sessionId);
    if keys[1].startsWith(CHECKPOINT_SESSION_PREFIX) {
        return error Error(string `Invalid session key: '${sessionId}'. Session ids must not start with ` +
            string `'${CHECKPOINT_SESSION_PREFIX}', which is reserved for checkpoint storage.`);
    }
    return keys;
}

isolated function splitSessionKey(SessionKeyConfig config, string sessionId) returns [string, string]|Error {
    if config is FixedActorSessionKeyConfig {
        if sessionId.length() == 0 {
            return error Error("Invalid session key: session key must not be empty.");
        }
        return [sanitizeActorId(config.actorId), sanitizeSessionId(sessionId)];
    }

    string separator = config.separator;
    int? splitAt = sessionId.indexOf(separator);
    boolean hasExactlyOneOccurrence = splitAt is int && sessionId.indexOf(separator, splitAt + 1) is ();
    if splitAt is () || !hasExactlyOneOccurrence || splitAt == 0 || splitAt == sessionId.length() - separator.length() {
        return error Error(string `Invalid session key: '${sessionId}' must contain the separator ` +
            string `'${separator}' exactly once, with a non-empty actor id and session id on ` +
            "either side.");
    }
    string rawActorId = sessionId.substring(0, splitAt);
    string rawSessionId = sessionId.substring(splitAt + separator.length());
    return [sanitizeActorId(rawActorId), sanitizeSessionId(rawSessionId)];
}
