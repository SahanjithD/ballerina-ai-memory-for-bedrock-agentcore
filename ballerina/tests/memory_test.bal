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

@test:Config
function testGetOnAnUnknownSessionIsEmpty() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    test:assertEquals((check memory.get("brand-new")).length(), 0);
    test:assertEquals(mockCallCount("ListEvents"), 1, "a plain get must issue exactly one ListEvents");
}

@test:Config
function testUpdateThenGetRoundTripsOneTurn() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    ai:ChatMessage[] turn = [
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "what is 2+2?"},
        {role: ai:ASSISTANT, content: "4"}
    ];

    check memory.update("chat-round-trip", turn);
    test:assertEquals(asJson(check memory.get("chat-round-trip")), asJson(turn));
    test:assertEquals(mockCallCount("CreateEvent"), 1, "one turn must be one event");
}

@test:Config
function testUpdateAcceptsASingleMessage() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    check memory.update("chat-single", <ai:ChatUserMessage>{role: ai:USER, content: "just me"});
    ai:ChatMessage[] messages = check memory.get("chat-single");
    test:assertEquals(messages.length(), 1);
    test:assertEquals(userContent(messages[0]), "just me");
}

@test:Config
function testUpdateWithNoMessagesWritesNothing() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    check memory.update("chat-empty", []);
    test:assertEquals(mockCallCount("CreateEvent"), 0);
}

@test:Config
function testFoldingKeepsOnlyTheLastSystemMessage() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    // `ai:Agent` resends the system message on every turn, so it must be deduplicated to the most
    // recent one while the interactive messages accumulate.
    check memory.update("chat-fold", [
        {role: ai:SYSTEM, content: "instruction v1"},
        {role: ai:USER, content: "one"},
        {role: ai:ASSISTANT, content: "first"}
    ]);
    check memory.update("chat-fold", [
        {role: ai:SYSTEM, content: "instruction v2"},
        {role: ai:USER, content: "two"},
        {role: ai:ASSISTANT, content: "second"}
    ]);

    ai:ChatMessage[] messages = check memory.get("chat-fold");
    test:assertEquals(asJson(messages), asJson(<ai:ChatMessage[]>[
        {role: ai:SYSTEM, content: "instruction v2"},
        {role: ai:USER, content: "one"},
        {role: ai:ASSISTANT, content: "first"},
        {role: ai:USER, content: "two"},
        {role: ai:ASSISTANT, content: "second"}
    ]));
}

@test:Config
function testToolCallTurnsRoundTrip() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    ai:ChatMessage[] turn = [
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "weather in Colombo?"},
        {role: ai:ASSISTANT, content: (), toolCalls: [{name: "weather", arguments: {"city": "Colombo"}, id: "c1"}]},
        {role: "function", name: "weather", content: "sunny", id: "c1"},
        {role: ai:ASSISTANT, content: "It is sunny."}
    ];

    check memory.update("chat-tools", turn);
    test:assertEquals(asJson(check memory.get("chat-tools")), asJson(turn));
}

@test:Config
function testEmptyToolResultsSurviveTheRoundTrip() returns error? {
    // An empty tool result is dropped from the extraction-only conversational items, but must still
    // come back from the blob - and must not make AWS reject the whole event.
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    ai:ChatMessage[] turn = [
        {role: ai:USER, content: "run the no-op"},
        {role: "function", name: "noop", content: "", id: "c1"},
        {role: ai:ASSISTANT, content: "done"}
    ];

    check memory.update("chat-empty-tool", turn);
    test:assertEquals(asJson(check memory.get("chat-empty-tool")), asJson(turn));
}

@test:Config
function testOversizedToolResultsSurviveTheRoundTrip() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    string huge = repeatString("y", MAX_CONVERSATIONAL_TEXT_LENGTH + 500);
    ai:ChatMessage[] turn = [
        {role: ai:USER, content: "fetch the big file"},
        {role: "function", name: "fetch", content: huge, id: "c1"}
    ];

    check memory.update("chat-huge-tool", turn);
    ai:ChatMessage[] messages = check memory.get("chat-huge-tool");
    test:assertEquals((<ai:ChatFunctionMessage>messages[1]).content, huge);
}

@test:Config
function testEventsAreSortedChronologicallyRegardlessOfServerOrder() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    foreach int i in 0 ..< 5 {
        check memory.update("chat-order", [<ai:ChatUserMessage>{role: ai:USER, content: string `m${i}`}]);
    }

    // `ListEvents` documents no ordering guarantee, so the module must not inherit the server's.
    setMockListOrderReversed(true);
    ai:ChatMessage[] messages = check memory.get("chat-order");
    test:assertEquals(from ai:ChatMessage message in messages select userContent(message),
            ["m0", "m1", "m2", "m3", "m4"]);
}

@test:Config
function testForeignEventsAreSkippedWithoutFailingTheGet() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    check memory.update("chat-foreign", [<ai:ChatUserMessage>{role: ai:USER, content: "ours"}]);

    // Events another SDK (or a future build of this module) wrote into the same memory resource.
    injectForeignEvent("user-42", "chat-foreign", [blobItem({"framework": "strands", "messages": []})], 2d);
    injectForeignEvent("user-42", "chat-foreign", [blobItem({"v": ENVELOPE_VERSION + 1, "messages": []})], 3d);
    injectForeignEvent("user-42", "chat-foreign",
            [{"conversational": {"content": {"text": "theirs"}, "role": ROLE_USER}}], 4d);
    injectForeignEvent("user-42", "chat-foreign", [blobItem({"v": ENVELOPE_VERSION, "messages": "broken"})], 5d);

    ai:ChatMessage[] messages = check memory.get("chat-foreign");
    test:assertEquals(messages.length(), 1);
    test:assertEquals(userContent(messages[0]), "ours");
}

@test:Config
function testSoftDeleteHidesHistoryWithoutRemovingEvents() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, SOFT));
    check memory.update("chat-soft", [<ai:ChatUserMessage>{role: ai:USER, content: "before"}]);

    check memory.delete("chat-soft");
    test:assertEquals((check memory.get("chat-soft")).length(), 0);
    test:assertEquals(mockCallCount("DeleteEvent"), 0, "SOFT must never call DeleteEvent");
    test:assertEquals(storedMockEvents("user-42", "chat-soft").length(), 2, "the turn and the marker both remain");

    // Writing after a reset marker starts a fresh visible history.
    check memory.update("chat-soft", [<ai:ChatUserMessage>{role: ai:USER, content: "after"}]);
    ai:ChatMessage[] messages = check memory.get("chat-soft");
    test:assertEquals(messages.length(), 1);
    test:assertEquals(userContent(messages[0]), "after");
}

@test:Config
function testOnlyTheLastResetMarkerCounts() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, SOFT));

    check memory.update("chat-two-resets", [<ai:ChatUserMessage>{role: ai:USER, content: "first"}]);
    check memory.delete("chat-two-resets");
    check memory.update("chat-two-resets", [<ai:ChatUserMessage>{role: ai:USER, content: "second"}]);
    check memory.delete("chat-two-resets");
    check memory.update("chat-two-resets", [<ai:ChatUserMessage>{role: ai:USER, content: "third"}]);

    ai:ChatMessage[] messages = check memory.get("chat-two-resets");
    test:assertEquals(messages.length(), 1);
    test:assertEquals(userContent(messages[0]), "third");
}

@test:Config
function testPhysicalPurgeKeepsTheResetMarker() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, PHYSICAL));
    check memory.update("chat-purge", [<ai:ChatUserMessage>{role: ai:USER, content: "one"}]);
    check memory.update("chat-purge", [<ai:ChatUserMessage>{role: ai:USER, content: "two"}]);

    check memory.delete("chat-purge");

    // Deleting the marker along with everything else would let a partially-failed purge silently
    // resurrect the remaining history on the next get().
    MockEvent[] remaining = storedMockEvents("user-42", "chat-purge");
    test:assertEquals(remaining.length(), 1, "exactly the reset marker must survive a purge");
    test:assertTrue(isResetMarker(remaining[0].payload), "the surviving event must be the reset marker");
    test:assertEquals(mockCallCount("DeleteEvent"), 2, "only the two prior events are deleted");
    test:assertEquals((check memory.get("chat-purge")).length(), 0);
}

@test:Config
function testPhysicalPurgeOfAnEmptySessionStillWritesAMarker() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, PHYSICAL));

    check memory.delete("chat-purge-empty");
    test:assertEquals(mockCallCount("DeleteEvent"), 0);
    test:assertEquals(storedMockEvents("user-42", "chat-purge-empty").length(), 1);
}

@test:Config
function testPhysicalPurgeLeavesOtherSessionsAlone() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, PHYSICAL));
    check memory.update("chat-keep", [<ai:ChatUserMessage>{role: ai:USER, content: "keep me"}]);
    check memory.update("chat-drop", [<ai:ChatUserMessage>{role: ai:USER, content: "drop me"}]);

    check memory.delete("chat-drop");

    test:assertEquals(storedMockEvents("user-42", "chat-keep").length(), 1);
    test:assertEquals(userContent((check memory.get("chat-keep"))[0]), "keep me");
}

@test:Config
function testUnsafeSessionKeysStayConsistentAcrossWriteReadAndDelete() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "tenant/acme:1"}, PHYSICAL));

    check memory.update("room:42", [<ai:ChatUserMessage>{role: ai:USER, content: "hidden behind a hash"}]);
    ai:ChatMessage[] messages = check memory.get("room:42");
    test:assertEquals(messages.length(), 1, "a hashed key must be read back under the same hash");

    string actorId = sanitizeActorId("tenant/acme:1");
    string sessionId = sanitizeSessionId("room:42");
    test:assertEquals(storedMockEvents(actorId, sessionId).length(), 1);

    check memory.delete("room:42");
    test:assertEquals(mockCallCount("DeleteEvent"), 1, "the delete path must find the same hashed session");
    test:assertEquals((check memory.get("room:42")).length(), 0);
}

@test:Config
function testCompositeSessionKeysSplitIntoActorAndSession() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({separator: "/"}));

    check memory.update("user-7/chat-9", [<ai:ChatUserMessage>{role: ai:USER, content: "hello"}]);
    test:assertEquals(storedMockEvents("user-7", "chat-9").length(), 1);

    // A different actor's identically-named session is a different session.
    check memory.update("user-8/chat-9", [<ai:ChatUserMessage>{role: ai:USER, content: "other"}]);
    test:assertEquals(userContent((check memory.get("user-7/chat-9"))[0]), "hello");
    test:assertEquals(userContent((check memory.get("user-8/chat-9"))[0]), "other");
}

@test:Config
function testInvalidCompositeKeyFailsWithAMemoryError() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({separator: "/"}));

    ai:ChatMessage[]|ai:MemoryError result = memory.get("no-separator");
    test:assertTrue(result is ai:MemoryError);
    test:assertTrue(memory.update("no-separator", [<ai:ChatUserMessage>{role: ai:USER, content: "x"}]) is ai:MemoryError);
    test:assertTrue(memory.delete("no-separator") is ai:MemoryError);
    test:assertEquals(mockCallCount("CreateEvent"), 0, "an unresolvable key must not reach AWS");
}

@test:Config
function testMaxEventsPerGetIsBoundedByTheAwsPageSize() {
    foreach int invalid in [0, -1, MAX_PAGE_SIZE + 1, 1000] {
        Memory|Error memory = new (mockMemoryConfig({actorId: "user-42"}, SOFT, invalid));
        test:assertTrue(memory is Error, string `maxEventsPerGet=${invalid} should be rejected`);
        test:assertTrue((<Error>memory).message().includes("Invalid maxEventsPerGet"));
    }
}

@test:Config
function testMaxEventsPerGetIsPassedToListEvents() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, SOFT, 3));
    foreach int i in 0 ..< 5 {
        check memory.update("chat-cap", [<ai:ChatUserMessage>{role: ai:USER, content: string `m${i}`}]);
    }

    // Still a single ListEvents call: `maxEventsPerGet` caps the page, it does not start paging.
    int callsBefore = mockCallCount("ListEvents");
    test:assertEquals((check memory.get("chat-cap")).length(), 3);
    test:assertEquals(mockCallCount("ListEvents"), callsBefore + 1);
}

@test:Config
function testGetDoesNotFollowAContinuationToken() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, SOFT, 2));
    foreach int i in 0 ..< 5 {
        check memory.update("chat-notoken", [<ai:ChatUserMessage>{role: ai:USER, content: string `m${i}`}]);
    }

    // The mock offers a `nextToken` here; `maxEventsPerGet` is capped at the AWS page size precisely
    // so `get` stays a single call, and a reintroduced pagination loop would show up as extra calls.
    int callsBefore = mockCallCount("ListEvents");
    test:assertEquals((check memory.get("chat-notoken")).length(), 2);
    test:assertEquals(mockCallCount("ListEvents"), callsBefore + 1);
}

@test:Config
function testAPlainTurnCostsOneListAndOneCreate() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    _ = check memory.get("chat-budget");
    check memory.update("chat-budget", [
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "hi"},
        {role: ai:ASSISTANT, content: "hello"}
    ]);

    test:assertEquals(mockCallCount("ListEvents"), 1);
    test:assertEquals(mockCallCount("CreateEvent"), 1);
    test:assertEquals(mockCallCount("DeleteEvent"), 0);
    test:assertEquals(mockCallCount("GetMemory"), 0);
}

@test:Config
function testPurgeRelistsFromScratchInsteadOfPaging() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}, PHYSICAL));
    check memory.update("chat-purge-paging", [<ai:ChatUserMessage>{role: ai:USER, content: "one"}]);
    check memory.update("chat-purge-paging", [<ai:ChatUserMessage>{role: ai:USER, content: "two"}]);

    check memory.delete("chat-purge-paging");

    // A token minted before the deletes started is not guaranteed to stay valid across them, so
    // each round must ask for a fresh list.
    test:assertTrue(mockCallCount("ListEvents") >= 2, "a purge must re-list after deleting");
    foreach json body in mockListEventsBodies() {
        test:assertFalse((<map<json>>body).hasKey("nextToken"), "a purge must never page with a token");
    }
}

@test:Config
function testVerifyMemoryAcceptsAnActiveResource() returns error? {
    resetMock();
    MemoryConfig config = mockMemoryConfig({actorId: "user-42"});
    config.verifyMemory = true;

    _ = check new Memory(config);
    test:assertEquals(mockCallCount("GetMemory"), 1);
}

@test:Config
function testVerifyMemoryRejectsAnInactiveResource() {
    resetMock();
    setMockMemoryStatus("CREATING");
    MemoryConfig config = mockMemoryConfig({actorId: "user-42"});
    config.verifyMemory = true;

    Memory|Error memory = new (config);
    test:assertTrue(memory is Error);
    test:assertTrue((<Error>memory).message().includes("is not active"));
}

@test:Config
function testVerifyMemorySurfacesAControlPlaneFailure() {
    resetMock();
    setMockFailures(1, 403, "AccessDeniedException", "GetMemory");
    MemoryConfig config = mockMemoryConfig({actorId: "user-42"});
    config.verifyMemory = true;

    Memory|Error memory = new (config);
    test:assertTrue(memory is Error);
    test:assertTrue((<Error>memory).message().includes("Failed to verify"));
}

@test:Config
function testVerifyMemoryIsSkippedByDefault() returns error? {
    resetMock();
    _ = check new Memory(mockMemoryConfig({actorId: "user-42"}));
    test:assertEquals(mockCallCount("GetMemory"), 0, "init must not need control-plane access by default");
}

@test:Config
function testUpdateFailuresAreSurfacedAsMemoryErrors() returns error? {
    resetMock();
    setMockFailures(MAX_RETRY_ATTEMPTS + 1, 403, "AccessDeniedException");
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));

    ai:MemoryError? result = memory.update("chat-denied", [<ai:ChatUserMessage>{role: ai:USER, content: "x"}]);
    test:assertTrue(result is ai:MemoryError);
    test:assertEquals(mockCallCount("CreateEvent"), 1, "403 is not retryable");
}

@test:Config
function testEventTimestampsAreStrictlyIncreasing() returns error? {
    resetMock();
    Memory memory = check new (mockMemoryConfig({actorId: "user-42"}));
    foreach int i in 0 ..< 10 {
        check memory.update("chat-ts", [<ai:ChatUserMessage>{role: ai:USER, content: string `m${i}`}]);
    }

    // Two turns completing within the same wall-clock tick must not collide, or the chronological
    // sort has nothing stable to order them by.
    decimal previous = -1;
    foreach MockEvent event in storedMockEvents("user-42", "chat-ts") {
        test:assertTrue(event.eventTimestamp > previous, "event timestamps must strictly increase");
        previous = event.eventTimestamp;
    }
}
