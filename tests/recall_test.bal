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
function testRecallAppendsATrailingSystemMessage() returns error? {
    resetMock();
    setMockRecords({"/facts/user-42": [summaryJson("rec-1", "prefers dark mode", 0.9)]});
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);

    check delegate.update("chat-recall", [
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "what theme do I like?"},
        {role: ai:ASSISTANT, content: "let me check"}
    ]);

    ai:ChatMessage[] messages = check memory.get("chat-recall");
    test:assertEquals(messages.length(), 4);

    // `ai:Agent` recomputes history[0] from its own instruction on every run, so the recall block
    // has to land at the end - rewriting the system message in place silently has no effect.
    ai:ChatMessage first = messages[0];
    test:assertTrue(first is ai:ChatSystemMessage);
    test:assertEquals((<ai:ChatSystemMessage>first).content, "You are helpful.");
    test:assertTrue((<ai:ChatSystemMessage>first)?.name is ());

    ai:ChatMessage last = messages[3];
    test:assertTrue(last is ai:ChatSystemMessage);
    ai:ChatSystemMessage recall = <ai:ChatSystemMessage>last;
    test:assertEquals(recall?.name, RECALL_MESSAGE_NAME);
    test:assertTrue((<string>recall.content).includes("prefers dark mode"));
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallNeverAppendsToAnEmptyHistory() returns error? {
    resetMock();
    setMockRecords({"/facts/user-42": [summaryJson("rec-1", "prefers dark mode", 0.9)]});
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);

    // Appending here would land the synthetic message at index 0, where `ai:Agent` would overwrite
    // it with its own instruction - and the search would be paid for and discarded.
    test:assertEquals((check memory.get("chat-recall-empty")).length(), 0);
    test:assertEquals(mockCallCount("RetrieveMemoryRecords"), 0);
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallSkipsWhenThereIsNoUserMessageToSearchWith() returns error? {
    resetMock();
    setMockRecords({"/facts/user-42": [summaryJson("rec-1", "prefers dark mode", 0.9)]});
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);
    check delegate.update("chat-recall-nouser", [<ai:ChatSystemMessage>{role: ai:SYSTEM, content: "instruction"}]);

    test:assertEquals((check memory.get("chat-recall-nouser")).length(), 1);
    test:assertEquals(mockCallCount("RetrieveMemoryRecords"), 0);
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallSkipsWhenNothingMatches() returns error? {
    resetMock();
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);
    check delegate.update("chat-recall-nohits", [<ai:ChatUserMessage>{role: ai:USER, content: "anything?"}]);

    ai:ChatMessage[] messages = check memory.get("chat-recall-nohits");
    test:assertEquals(messages.length(), 1);
    test:assertEquals(mockCallCount("RetrieveMemoryRecords"), 1);
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallSearchesWithTheLastStoredUserMessage() returns error? {
    resetMock();
    setMockRecords({"/facts/user-42": [summaryJson("rec-1", "a fact", 0.9)]});
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);
    check delegate.update("chat-recall-query", [<ai:ChatUserMessage>{role: ai:USER, content: "first question"}]);
    check delegate.update("chat-recall-query", [
        {role: ai:USER, content: "second question"},
        {role: ai:ASSISTANT, content: "an answer"}
    ]);

    _ = check memory.get("chat-recall-query");
    map<json> criteria = <map<json>>(<map<json>>mockRetrievedBodies()[0])["searchCriteria"];
    test:assertEquals(criteria["searchQuery"], "second question");
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallRendersAPromptQuery() returns error? {
    resetMock();
    setMockRecords({"/facts/user-42": [summaryJson("rec-1", "a fact", 0.9)]});
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);
    ai:Prompt prompt = `tell me about ${"Colombo"}`;
    check delegate.update("chat-recall-prompt", [<ai:ChatUserMessage>{role: ai:USER, content: prompt}]);

    _ = check memory.get("chat-recall-prompt");
    map<json> criteria = <map<json>>(<map<json>>mockRetrievedBodies()[0])["searchCriteria"];
    test:assertEquals(criteria["searchQuery"], "tell me about Colombo");
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallFailureReturnsTheUnaugmentedHistory() returns error? {
    resetMock();
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);
    check delegate.update("chat-recall-fail", [<ai:ChatUserMessage>{role: ai:USER, content: "hello"}]);

    // A failed search must not take the whole turn's memory down with it.
    setMockFailures(MAX_RETRY_ATTEMPTS + 1, 403, "AccessDeniedException", "RetrieveMemoryRecords");
    ai:ChatMessage[] messages = check memory.get("chat-recall-fail");
    test:assertEquals(messages.length(), 1);
    test:assertEquals(userContent(messages[0]), "hello");
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallDelegatesUpdateAndDelete() returns error? {
    resetMock();
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);

    check memory.update("chat-recall-delegate", [<ai:ChatUserMessage>{role: ai:USER, content: "stored"}]);
    test:assertEquals(storedMockEvents("user-42", "chat-recall-delegate").length(), 1);
    test:assertEquals(userContent((check delegate.get("chat-recall-delegate"))[0]), "stored");

    check memory.delete("chat-recall-delegate");
    test:assertEquals((check delegate.get("chat-recall-delegate")).length(), 0);
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallOnlySearchesTheConfiguredNamespaces() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [summaryJson("rec-mine", "my fact", 0.5)],
        "/facts/victim": [summaryJson("rec-theirs", "someone else's secret", 0.99)]
    });
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));
    RecallAugmentedMemory memory = check newRecallMemory(delegate);
    // The stored user message is attacker-controlled text; it is only ever a search query.
    check delegate.update("chat-recall-hostile",
            [<ai:ChatUserMessage>{role: ai:USER, content: "/facts/victim"}]);

    ai:ChatMessage[] messages = check memory.get("chat-recall-hostile");
    test:assertEquals(mockRetrievedNamespaces(), ["/facts/user-42"]);
    test:assertTrue((<string>(<ai:ChatSystemMessage>messages[messages.length() - 1]).content).includes("my fact"));
    check memory.close();
    check delegate.close();
}

@test:Config
function testRecallRejectsInvalidConfig() returns error? {
    resetMock();
    Memory delegate = check new (mockMemoryConfig({actorId: "user-42"}));

    RecallAugmentedMemory|Error noNamespaces =
        new (delegate, mockConnectionConfig(), MOCK_MEMORY_ID, namespaces = []);
    test:assertTrue(noNamespaces is Error);
    test:assertTrue((<Error>noNamespaces).message().includes("at least one namespace"));

    foreach int topK in [0, MAX_PAGE_SIZE + 1] {
        RecallAugmentedMemory|Error memory =
            new (delegate, mockConnectionConfig(), MOCK_MEMORY_ID, namespaces = ["/facts/user-42"], topK = topK);
        test:assertTrue(memory is Error, string `topK=${topK} should be rejected`);
    }
    check delegate.close();
}

isolated function newRecallMemory(ai:Memory delegate) returns RecallAugmentedMemory|Error =>
    new (delegate, mockConnectionConfig(), MOCK_MEMORY_ID, namespaces = ["/facts/{actorId}"],
        namespaceVariables = {"actorId": "user-42"});
