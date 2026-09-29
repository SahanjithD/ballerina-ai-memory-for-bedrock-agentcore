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
function testStringContentMessagesRoundTrip() returns error? {
    ai:ChatMessage[] messages = [
        {role: ai:SYSTEM, content: "instructions"},
        {role: ai:SYSTEM, content: "named instructions", name: "policy"},
        {role: ai:USER, content: "hello"},
        {role: ai:USER, content: "hello", name: "dasun"},
        {role: ai:ASSISTANT, content: "hi there"},
        {role: ai:ASSISTANT, content: (), toolCalls: [{name: "t", arguments: {"k": "v"}, id: "c1"}]},
        {role: ai:ASSISTANT, content: "done", toolCalls: ()},
        {role: "function", name: "t", content: "result", id: "c1"},
        {role: "function", name: "t", content: ()}
    ];

    foreach ai:ChatMessage message in messages {
        ai:ChatMessage restored = check roundTrip(message);
        test:assertEquals(asJson([restored]), asJson([message]), message.toString());
    }
}

@test:Config
function testPromptContentRoundTrips() returns error? {
    ai:Prompt prompt = `Summarise ${"the report"} for ${42} readers.`;
    ai:ChatUserMessage message = {role: ai:USER, content: prompt};

    ai:ChatMessage restored = check roundTrip(message);
    string|ai:Prompt content = (<ai:ChatUserMessage>restored).content;
    test:assertTrue(content is ai:Prompt, "a Prompt must not degrade to a plain string");

    ai:Prompt restoredPrompt = <ai:Prompt>content;
    test:assertEquals(restoredPrompt.strings, prompt.strings);
    test:assertEquals(restoredPrompt.insertions, prompt.insertions);
}

@test:Config
function testPromptContentRoundTripsOnASystemMessage() returns error? {
    ai:Prompt prompt = `You are ${"a helpful"} assistant.`;
    ai:ChatMessage restored = check roundTrip(<ai:ChatSystemMessage>{role: ai:SYSTEM, content: prompt, name: "sys"});

    ai:ChatSystemMessage system = <ai:ChatSystemMessage>restored;
    test:assertEquals(system?.name, "sys");
    test:assertEquals(renderContent(system.content), "You are a helpful assistant.");
}

@test:Config
function testStoredPromptIsPlainJson() {
    ai:Prompt prompt = `a ${1} b ${true} c`;
    DatabaseMessage stored = toDatabaseMessage(<ai:ChatUserMessage>{role: ai:USER, content: prompt});

    test:assertEquals(stored.toJson(), {
        "role": "user",
        "content": {"strings": ["a ", " b ", " c"], "insertions": [1, true]}
    });
}

@test:Config
function testRenderContentInterleavesStringsAndInsertions() {
    test:assertEquals(renderContent("plain"), "plain");
    test:assertEquals(renderContent(`no insertions`), "no insertions");
    test:assertEquals(renderContent(`${"leading"} then tail`), "leading then tail");
    test:assertEquals(renderContent(`a${1}b${2}c`), "a1b2c");
    test:assertEquals(renderContent(`count: ${3.5}`), "count: 3.5");
}

// The stored form is what actually crosses the wire (as a JSON string inside the blob), so the
// round trip is asserted through JSON text rather than through the in-memory record.
isolated function roundTrip(ai:ChatMessage message) returns ai:ChatMessage|error {
    json encoded = check toDatabaseMessage(message).toJsonString().fromJsonString();
    DatabaseMessage decoded = check encoded.fromJsonWithType();
    return fromDatabaseMessage(decoded);
}
