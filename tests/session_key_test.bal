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

@test:Config
function testFixedActorResolvesKeyAsSessionId() returns error? {
    [string, string] keys = check resolveSessionKey({actorId: "svc-agent"}, "chat-7");
    test:assertEquals(keys, ["svc-agent", "chat-7"]);
}

@test:Config
function testFixedActorRejectsEmptyKey() {
    [string, string]|Error keys = resolveSessionKey({actorId: "svc-agent"}, "");
    test:assertTrue(keys is Error);
    test:assertTrue((<Error>keys).message().includes("must not be empty"));
}

@test:Config
function testCompositeSplitsOnTheDefaultSeparator() returns error? {
    [string, string] keys = check resolveSessionKey({}, "user-42/chat-7");
    test:assertEquals(keys, ["user-42", "chat-7"]);
}

@test:Config
function testCompositeSplitsOnACustomSeparator() returns error? {
    [string, string] keys = check resolveSessionKey({separator: "::"}, "user-42::chat-7");
    test:assertEquals(keys, ["user-42", "chat-7"]);
}

@test:Config
function testCompositeRequiresExactlyOneSeparator() {
    string[] invalid = [
        "no-separator",
        "user-42/chat/extra", // two separators: which half is the actor is ambiguous
        "/chat-7", // empty actor id
        "user-42/", // empty session id
        "/",
        "user-42//chat-7"
    ];
    foreach string key in invalid {
        [string, string]|Error keys = resolveSessionKey({}, key);
        test:assertTrue(keys is Error, string `expected '${key}' to be rejected`);
        test:assertTrue((<Error>keys).message().includes("exactly once"));
    }
}

@test:Config
function testCompositeRejectsRepeatedMultiCharSeparator() {
    [string, string]|Error keys = resolveSessionKey({separator: "::"}, "a::b::c");
    test:assertTrue(keys is Error);
}

@test:Config
function testSafeIdsArePassedThroughUnchanged() {
    foreach string id in ["a", "A9", "user-42", "user_42", "abc-DEF_123"] {
        test:assertEquals(sanitizeActorId(id), id);
        test:assertEquals(sanitizeSessionId(id), id);
    }
}

@test:Config
function testUnsafeCharactersAreHashed() {
    // `/` would split into an extra URI path segment; `:` is encoded by the signer but not on the
    // wire. Both must be replaced before the id reaches a path.
    foreach string id in ["tenant/user-42", "arn-ish:thing", "has space", "emoji-\u{1F600}", "-leading-dash", "_leading"] {
        string sanitized = sanitizeActorId(id);
        test:assertTrue(isSafeId(sanitized), string `'${id}' sanitized to an unsafe '${sanitized}'`);
        test:assertTrue(sanitized.startsWith("h-"));
        test:assertEquals(sanitized.length(), 66); // "h-" plus a hex SHA-256
    }
}

@test:Config
function testOverlongIdsAreHashed() {
    string longId = repeatString("a", MAX_SESSION_ID_LENGTH + 1);
    test:assertTrue(sanitizeSessionId(longId).startsWith("h-"));
    // The same string is inside the actor id's much larger budget, so it passes through there.
    test:assertEquals(sanitizeActorId(longId), longId);
    test:assertTrue(sanitizeActorId(repeatString("a", MAX_ACTOR_ID_LENGTH + 1)).startsWith("h-"));
    test:assertEquals(sanitizeSessionId(repeatString("a", MAX_SESSION_ID_LENGTH)),
            repeatString("a", MAX_SESSION_ID_LENGTH));
}

@test:Config
function testSanitizationIsDeterministicAndIdempotent() {
    string raw = "tenant/user-42";
    string once = sanitizeActorId(raw);
    test:assertEquals(sanitizeActorId(raw), once, "the same raw id must always map to the same safe id");
    test:assertEquals(sanitizeId(raw, MAX_ACTOR_ID_LENGTH), once);
    test:assertEquals(sanitizeActorId(once), once, "an already-safe id must survive a second pass");
    test:assertNotEquals(sanitizeActorId("tenant/user-43"), once);
}

@test:Config
function testResolversAgreeOnTheSanitizedPairAcrossCalls() returns error? {
    // The write path, read path and delete path each resolve the key independently; they must
    // agree, or a session written under a hashed id is invisible to the next get().
    [string, string] first = check resolveSessionKey({}, "tenant:x/chat:7");
    [string, string] second = check resolveSessionKey({}, "tenant:x/chat:7");
    test:assertEquals(first, second);
    test:assertTrue(isSafeId(first[0]) && isSafeId(first[1]));

    [string, string] fixed = check resolveSessionKey({actorId: "svc/agent"}, "chat:7");
    test:assertEquals(fixed, check resolveSessionKey({actorId: "svc/agent"}, "chat:7"));
    test:assertTrue(isSafeId(fixed[0]) && isSafeId(fixed[1]));
}

isolated function isSafeId(string id) returns boolean => SAFE_ID_PATTERN.isFullMatch(id);
