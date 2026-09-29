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
function testDefaultConfigCreatesTheMemoryAndUsesIt() returns error? {
    resetMock();
    Memory memory = check new (mockProvisionedConfig());

    test:assertEquals(mockCallCount("CreateMemory"), 1);
    map<json> body = <map<json>>mockCreateMemoryBodies()[0];
    test:assertEquals(body["name"], "chat_memory");
    test:assertEquals(body["eventExpiryDuration"], 90);
    test:assertTrue(body["clientToken"] is string, "CreateMemory must carry a clientToken for idempotent retries");

    // The created resource's id is the one every data-plane call goes to.
    string createdId = mockMemoryIds()[0];
    check memory.update("chat-provisioned", [<ai:ChatUserMessage>{role: ai:USER, content: "hello"}]);
    test:assertEquals(storedMockEvents("user-42", "chat-provisioned", createdId).length(), 1);
    test:assertEquals((check memory.get("chat-provisioned")).length(), 1);
}

@test:Config
function testAnExistingMemoryIsReusedByName() returns error? {
    resetMock();
    string existingId = seedMockMemory("chat_memory");

    Memory memory = check new (mockProvisionedConfig());
    test:assertEquals(mockCallCount("CreateMemory"), 0, "an existing memory must not be created again");
    check memory.update("chat-existing", [<ai:ChatUserMessage>{role: ai:USER, content: "hi"}]);
    test:assertEquals(storedMockEvents("user-42", "chat-existing", existingId).length(), 1);
}

@test:Config
function testASecondInitFindsTheMemoryTheFirstCreated() returns error? {
    resetMock();
    _ = check new Memory(mockProvisionedConfig());
    _ = check new Memory(mockProvisionedConfig());
    test:assertEquals(mockCallCount("CreateMemory"), 1);
    test:assertEquals(mockMemoryIds().length(), 1);
}

@test:Config
function testCreationCanBeDisabled() {
    resetMock();
    Memory|Error memory = new (mockProvisionedConfig({createMemoryIfNotExists: false}));
    test:assertTrue(memory is Error);
    test:assertTrue((<Error>memory).message().includes("createMemoryIfNotExists is false"));
    test:assertEquals(mockCallCount("CreateMemory"), 0);
}

@test:Config
function testDisabledCreationStillFindsAnExistingMemory() returns error? {
    resetMock();
    string existingId = seedMockMemory("support_memory");
    Memory memory = check new (mockProvisionedConfig({memoryName: "support_memory", createMemoryIfNotExists: false}));
    check memory.update("chat-find", [<ai:ChatUserMessage>{role: ai:USER, content: "hi"}]);
    test:assertEquals(storedMockEvents("user-42", "chat-find", existingId).length(), 1);
}

@test:Config
function testLosingACreationRaceUsesTheWinnersMemory() returns error? {
    resetMock();
    // Another replica created the memory between our lookup and our create: our first lookup sees
    // nothing, our CreateMemory gets a name conflict, and the retry lookup finds theirs.
    string winnerId = seedMockMemory("chat_memory");
    hideMockMemoriesFromNextLists(1);

    Memory memory = check new (mockProvisionedConfig());
    test:assertEquals(mockCallCount("CreateMemory"), 1);
    test:assertEquals(mockMemoryIds().length(), 1, "no second memory may be created");
    check memory.update("chat-race", [<ai:ChatUserMessage>{role: ai:USER, content: "hi"}]);
    test:assertEquals(storedMockEvents("user-42", "chat-race", winnerId).length(), 1);
}

@test:Config
function testAFailedMemorySurfacesItsReason() {
    resetMock();
    setMockNewMemoryBehavior(0, "FAILED", "execution role is not assumable");
    Memory|Error memory = new (mockProvisionedConfig());
    test:assertTrue(memory is Error);
    test:assertTrue((<Error>memory).message().includes("execution role is not assumable"));
}

@test:Config
function testAMemoryBeingDeletedIsRejected() {
    resetMock();
    _ = seedMockMemory("chat_memory", "DELETING");
    Memory|Error memory = new (mockProvisionedConfig());
    test:assertTrue(memory is Error);
    test:assertTrue((<Error>memory).message().includes("is being deleted"));
}

@test:Config
function testWaitingPollsUntilTheMemoryIsActive() returns error? {
    resetMock();
    setMockNewMemoryBehavior(3);
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    string id = check resolveMemoryId(agentCoreClient, {}, 0.01);
    test:assertEquals(id, mockMemoryIds()[0]);
    test:assertEquals(mockCallCount("GetMemory"), 4, "three CREATING polls, then ACTIVE");
}

@test:Config
function testANotFoundRightAfterCreateIsReportedAsTransient() returns error? {
    resetMock();
    // The control plane is eventually consistent: a brand-new memory can briefly read as missing.
    setMockFailures(1, 404, "ResourceNotFoundException", "GetMemory");
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    _ = check resolveMemoryId(agentCoreClient, {}, 0.01);
    test:assertEquals(mockCallCount("GetMemory"), 2);
}

@test:Config
function testNameLookupDoesNotMatchAPrefixOfAnotherName() returns error? {
    resetMock();
    // `chat_memory_v2`'s id also starts with "chat_memory"; it must not be mistaken for it.
    _ = seedMockMemory("chat_memory_v2", id = "chat_memory_v2-abcdefghij");
    _ = check new Memory(mockProvisionedConfig());
    test:assertEquals(mockCallCount("CreateMemory"), 1, "chat_memory must still be created");
    test:assertEquals(mockMemoryIds().length(), 2);
}

@test:Config
function testIdsForAName() {
    test:assertTrue(isIdForName("chat_memory-Ab12Cd34Ef", "chat_memory"));
    test:assertFalse(isIdForName("chat_memory_v2-Ab12Cd34Ef", "chat_memory"));
    test:assertFalse(isIdForName("chat_memory-short", "chat_memory"));
    test:assertFalse(isIdForName("chat_memory-Ab12Cd34Ef9", "chat_memory"));
    test:assertFalse(isIdForName("other-Ab12Cd34Ef", "chat_memory"));
}

@test:Config
function testInvalidResourceConfigIsRejectedBeforeAnyCall() {
    resetMock();
    MemoryResourceConfig[] invalid = [
        {memoryName: "has-hyphen"},
        {memoryName: "9starts_with_digit"},
        {memoryName: repeatString("a", 49)},
        {eventExpiryDuration: 2},
        {eventExpiryDuration: 366}
    ];
    foreach MemoryResourceConfig config in invalid {
        Memory|Error memory = new (mockProvisionedConfig(config));
        test:assertTrue(memory is Error, string `${config.toString()} should be rejected`);
    }
    test:assertEquals(mockCallCount("ListMemories") + mockCallCount("CreateMemory"), 0);
}

@test:Config
function testOptionalCreateFieldsAreSent() returns error? {
    resetMock();
    _ = check new Memory(mockProvisionedConfig({
        memoryName: "tagged_memory",
        eventExpiryDuration: 7,
        description: "support agent history",
        tags: {"team": "support"}
    }));
    map<json> body = <map<json>>mockCreateMemoryBodies()[0];
    test:assertEquals(body["eventExpiryDuration"], 7);
    test:assertEquals(body["description"], "support agent history");
    test:assertEquals(body["tags"], {"team": "support"});
    test:assertFalse(body.hasKey("encryptionKeyArn"), "unset optional fields must not be sent");
}

@test:Config
function testAnExplicitMemoryIdMakesNoControlPlaneCalls() returns error? {
    resetMock();
    _ = check new Memory(mockMemoryConfig({actorId: "user-42"}));
    test:assertEquals(mockCallCount("ListMemories") + mockCallCount("CreateMemory") + mockCallCount("GetMemory"), 0,
            "a memoryId-configured memory must work with data-plane permissions only");
}
