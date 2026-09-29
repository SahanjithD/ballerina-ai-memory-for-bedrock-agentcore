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

import ballerina/ai;
import ballerina/test;

isolated function sampleApproval(string sessionId, string executionId = "exec-1") returns ai:PendingApproval => {
    sessionId,
    executionId,
    iterationsUsed: 1,
    history: [
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "refund order 7"},
        {role: ai:ASSISTANT, content: (), toolCalls: [{name: "refund", arguments: {"orderId": "7"}, id: "c1"}]}
    ],
    historyPrefixLength: 2,
    iterations: [
        {
            history: [{role: ai:USER, content: "refund order 7"}],
            output: [error ai:Error("model returned malformed JSON")],
            startTime: [1758000000, 0.25],
            endTime: [1758000001, 0.5]
        }
    ],
    toolCalls: [{name: "refund", arguments: {"orderId": "7"}, id: "c1"}],
    startTime: [1758000000, 0.125],
    originalBatch: [{name: "refund", arguments: {"orderId": "7"}, id: "c1"}],
    pendingRequests: [
        {
            id: "req-1",
            sessionId,
            toolName: "refund",
            toolDescription: "Refunds an order",
            arguments: {"orderId": "7"},
            toolCallId: "c1",
            batchIndex: 0
        }
    ],
    decisions: [()]
};

// Checkpoints go to their own reserved AgentCore session, never the conversation session.
isolated function checkpointEvents(string actorId, string sessionKey) returns MockEvent[] =>
    storedMockEvents(actorId, checkpointSessionId(sanitizeSessionId(sessionKey)));

@test:Config
function testGetCheckpointWithNonePendingIsNil() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    test:assertEquals(check memory.getCheckpoint("chat-none"), ());
}

@test:Config
function testPutThenGetCheckpointRoundTrips() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    ai:PendingApproval approval = sampleApproval("chat-ckpt");

    check memory.putCheckpoint(approval);
    ai:PendingApproval? stored = check memory.getCheckpoint("chat-ckpt");
    test:assertTrue(stored is ai:PendingApproval);
    // Compared through the JSON-safe form: an iteration's `ai:Error` output only survives as its
    // message, which is exactly what that form captures.
    test:assertEquals(toStoredApproval(<ai:PendingApproval>stored), toStoredApproval(approval));
    ai:ChatAssistantMessage|ai:ChatFunctionMessage|ai:Error output = (<ai:PendingApproval>stored).iterations[0].output[0];
    test:assertTrue(output is ai:Error);
    test:assertEquals((<ai:Error>output).message(), "model returned malformed JSON");
}

@test:Config
function testCheckpointsStayOutOfTheConversationSession() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    check memory.update("chat-split", [<ai:ChatUserMessage>{role: ai:USER, content: "hello"}]);

    check memory.putCheckpoint(sampleApproval("chat-split"));

    test:assertEquals(storedMockEvents("user-42", "chat-split").length(), 1, "only the turn lives in the session");
    test:assertEquals(checkpointEvents("user-42", "chat-split").length(), 1);
    ai:ChatMessage[] messages = check memory.get("chat-split");
    test:assertEquals(messages.length(), 1, "a checkpoint must never surface as history");
}

@test:Config
function testPutCheckpointReplacesThePreviousOne() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    check memory.putCheckpoint(sampleApproval("chat-replace", "exec-old"));
    check memory.putCheckpoint(sampleApproval("chat-replace", "exec-new"));

    test:assertEquals(checkpointEvents("user-42", "chat-replace").length(), 1, "the older checkpoint must be removed");
    test:assertEquals((<ai:PendingApproval>check memory.getCheckpoint("chat-replace")).executionId, "exec-new");
}

@test:Config
function testTakeCheckpointClaimsItOnce() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    check memory.putCheckpoint(sampleApproval("chat-take"));

    ai:PendingApproval? first = check memory.takeCheckpoint("chat-take");
    test:assertTrue(first is ai:PendingApproval);
    test:assertEquals(check memory.takeCheckpoint("chat-take"), (), "a claimed checkpoint cannot be claimed again");
    test:assertEquals(check memory.getCheckpoint("chat-take"), ());
    test:assertEquals(checkpointEvents("user-42", "chat-take").length(), 0);
}

@test:Config
function testTakeCheckpointLosingTheRaceReturnsNil() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    check memory.putCheckpoint(sampleApproval("chat-race"));

    // Another resume deleted the event between our list and our claim: its DeleteEvent won, ours
    // sees 404, and we must report "nothing to claim" rather than an error or the approval.
    setMockFailures(1, 404, "ResourceNotFoundException", "DeleteEvent");
    test:assertEquals(check memory.takeCheckpoint("chat-race"), ());
}

@test:Config
function testTakeCheckpointAlsoClearsStaleOlderCheckpoints() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    string checkpointSession = checkpointSessionId(sanitizeSessionId("chat-stale"));
    // Left behind by an earlier put whose cleanup never ran.
    injectForeignEvent("user-42", checkpointSession, buildCheckpointPayload(sampleApproval("chat-stale", "exec-a")), 1d);
    injectForeignEvent("user-42", checkpointSession, buildCheckpointPayload(sampleApproval("chat-stale", "exec-b")), 2d);

    ai:PendingApproval? taken = check memory.takeCheckpoint("chat-stale");
    test:assertEquals((<ai:PendingApproval>taken).executionId, "exec-b", "the latest checkpoint wins");
    test:assertEquals(check memory.getCheckpoint("chat-stale"), (), "the stale one must not resurface");
}

@test:Config
function testRemoveCheckpointClearsIt() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    check memory.putCheckpoint(sampleApproval("chat-remove"));

    check memory.removeCheckpoint("chat-remove");
    test:assertEquals(check memory.getCheckpoint("chat-remove"), ());
    check memory.removeCheckpoint("chat-remove");
}

@test:Config
function testDeleteAlsoClearsThePendingCheckpoint() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, SOFT));
    check memory.update("chat-abandon", [<ai:ChatUserMessage>{role: ai:USER, content: "hi"}]);
    check memory.putCheckpoint(sampleApproval("chat-abandon"));

    check memory.delete("chat-abandon");
    test:assertEquals(check memory.getCheckpoint("chat-abandon"), (), "an abandoned pause must not outlive its session");
    test:assertEquals((check memory.get("chat-abandon")).length(), 0);
}

@test:Config
function testCheckpointsAreScopedPerSession() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({separator: "/"}));
    check memory.putCheckpoint(sampleApproval("user-1/chat-1", "exec-1"));

    test:assertEquals(check memory.getCheckpoint("user-2/chat-1"), (), "another actor's session must not see it");
    test:assertEquals(check memory.getCheckpoint("user-1/chat-2"), (), "another session must not see it");
    test:assertEquals((<ai:PendingApproval>check memory.getCheckpoint("user-1/chat-1")).executionId, "exec-1");
}

@test:Config
function testForeignEventsInTheCheckpointSessionAreIgnored() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    string checkpointSession = checkpointSessionId(sanitizeSessionId("chat-foreign-ckpt"));
    injectForeignEvent("user-42", checkpointSession, [blobItem({"v": ENVELOPE_VERSION, "kind": "something-else"})], 5d);

    test:assertEquals(check memory.getCheckpoint("chat-foreign-ckpt"), ());
    test:assertEquals(check memory.takeCheckpoint("chat-foreign-ckpt"), ());
}

@test:Config
function testReservedCheckpointSessionKeysAreRejected() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    string reserved = CHECKPOINT_SESSION_PREFIX + "anything";

    test:assertTrue(memory.get(reserved) is ai:MemoryError);
    test:assertTrue(memory.update(reserved, [<ai:ChatUserMessage>{role: ai:USER, content: "x"}]) is ai:MemoryError);
    test:assertTrue(memory.getCheckpoint(reserved) is Error);
    test:assertEquals(mockCallCount("CreateEvent") + mockCallCount("ListEvents"), 0,
            "a reserved key must not reach AWS");
}

@test:Config
function testCheckpointFailuresSurfaceAsErrors() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    setMockFailures(MAX_RETRY_ATTEMPTS + 1, 403, "AccessDeniedException");

    test:assertTrue(memory.putCheckpoint(sampleApproval("chat-denied-ckpt")) is Error);
}

