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
function testBuildEventPayloadPutsBlobFirst() {
    json[] payload = buildEventPayload([
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "hi"},
        {role: ai:ASSISTANT, content: "hello"}
    ]);

    test:assertEquals(payload.length(), 3);
    map<json> first = <map<json>>payload[0];
    test:assertTrue(first.hasKey("blob"));
    map<json> blob = <map<json>>first["blob"];
    test:assertEquals(blob["v"], ENVELOPE_VERSION);
    test:assertEquals(blob["reset"], false);
    test:assertEquals((<json[]>blob["messages"]).length(), 3);
}

@test:Config
function testConversationalItemsSkipSystemAndMapRoles() {
    json[] payload = buildEventPayload([
        {role: ai:SYSTEM, content: "You are helpful."},
        {role: ai:USER, content: "what is 2+2?"},
        {role: ai:ASSISTANT, content: (), toolCalls: [{name: "calc", arguments: {"a": 2}}]},
        {role: "function", name: "calc", content: "4"},
        {role: ai:ASSISTANT, content: "It is 4."}
    ]);

    // blob + user + tool result + final assistant: the system message and the content-less
    // tool-call assistant message render nothing.
    test:assertEquals(payload.length(), 4);
    test:assertEquals(conversationalRoles(payload), [ROLE_USER, ROLE_TOOL, ROLE_ASSISTANT]);
}

@test:Config
function testEmptyConversationalTextIsDropped() {
    json[] payload = buildEventPayload([
        {role: ai:USER, content: ""},
        {role: "function", name: "noop", content: ""},
        {role: ai:ASSISTANT, content: ""},
        {role: ai:USER, content: "real"}
    ]);

    test:assertEquals(payload.length(), 2, "empty-text items must never reach the wire");
    test:assertEquals(conversationalTexts(payload), ["real"]);
    // The blob still carries all four messages losslessly.
    map<json> blob = <map<json>>(<map<json>>payload[0])["blob"];
    test:assertEquals((<json[]>blob["messages"]).length(), 4);
}

@test:Config
function testOversizedConversationalTextIsTruncated() {
    string oversized = repeatString("x", MAX_CONVERSATIONAL_TEXT_LENGTH) + "tail";

    json[] payload = buildEventPayload([{role: ai:USER, content: oversized}]);
    string[] texts = conversationalTexts(payload);
    test:assertEquals(texts.length(), 1);
    test:assertEquals(texts[0].length(), MAX_CONVERSATIONAL_TEXT_LENGTH);

    // The blob keeps the untruncated original.
    ai:ChatMessage[] decoded = <ai:ChatMessage[]>decodeEventPayload(payload);
    test:assertEquals(userContent(decoded[0]), oversized);
}

@test:Config
function testConversationalItemsAreCappedToLeaveRoomForTheBlob() {
    ai:ChatMessage[] messages = from int i in 0 ..< 150 select {role: ai:USER, content: string `m${i}`};
    json[] payload = buildEventPayload(messages);

    test:assertEquals(payload.length(), MAX_PAYLOAD_ITEMS);
    test:assertEquals(conversationalTexts(payload).length(), MAX_CONVERSATIONAL_ITEMS_PER_EVENT);
    // Nothing is lost from the blob, only from the extraction-only items.
    test:assertEquals((<ai:ChatMessage[]>decodeEventPayload(payload)).length(), 150);
}

@test:Config
function testResetMarkerPayload() {
    json[] payload = buildResetMarkerPayload();
    test:assertEquals(payload.length(), 1);
    test:assertTrue(isResetMarker(payload));
    test:assertEquals((<ai:ChatMessage[]>decodeEventPayload(payload)).length(), 0);
}

@test:Config
function testOrdinaryTurnIsNotAResetMarker() {
    test:assertFalse(isResetMarker(buildEventPayload([{role: ai:USER, content: "hi"}])));
}

@test:Config
function testEnvelopeRoundTripsEveryMessageKind() returns error? {
    ai:ChatMessage[] messages = [
        {role: ai:SYSTEM, content: "You are helpful.", name: "instruction"},
        {role: ai:USER, content: "what is the weather?", name: "dasun"},
        {role: ai:ASSISTANT, content: (), toolCalls: [{name: "weather", arguments: {"city": "Colombo"}, id: "call-1"}]},
        {role: "function", name: "weather", content: "sunny", id: "call-1"},
        {role: ai:ASSISTANT, content: "It is sunny."}
    ];

    json[] payload = buildEventPayload(messages);
    // Round-trip through JSON text the way the wire does, not just through the in-memory value.
    json[] overTheWire = <json[]>check payload.toJsonString().fromJsonString();
    ai:ChatMessage[]? decoded = decodeEventPayload(overTheWire);

    test:assertTrue(decoded is ai:ChatMessage[]);
    test:assertEquals(asJson(<ai:ChatMessage[]>decoded), asJson(messages));
}

@test:Config
function testForeignBlobIsSkippedRatherThanFailing() {
    json[][] foreign = [
        [{"blob": {"framework": "strands", "messages": []}}],
        [{"blob": {"v": ENVELOPE_VERSION + 1, "messages": []}}],
        [{"conversational": {"content": {"text": "hi"}, "role": ROLE_USER}}],
        [{"blob": "a plain string blob"}],
        [{"blob": {"v": "1", "messages": []}}],
        ["not even an object"],
        []
    ];
    foreach json[] payload in foreign {
        test:assertTrue(decodeEventPayload(payload) is (), string `expected no envelope in ${payload.toJsonString()}`);
        test:assertFalse(isResetMarker(payload));
    }
}

@test:Config
function testBlobWithMatchingVersionButUndecodableShapeIsSkipped() {
    json[][] undecodable = [
        [{"blob": {"v": ENVELOPE_VERSION, "messages": "not an array"}}],
        [{"blob": {"v": ENVELOPE_VERSION}}],
        [{"blob": {"v": ENVELOPE_VERSION, "messages": [{"role": "bogus"}]}}]
    ];
    foreach json[] payload in undecodable {
        test:assertTrue(decodeEventPayload(payload) is ());
        test:assertFalse(isResetMarker(payload));
    }
}

@test:Config
function testBlobIsFoundBehindForeignItems() {
    json[] payload = [
        {"conversational": {"content": {"text": "hi"}, "role": ROLE_USER}},
        {"blob": {"unrelated": true}},
        ...buildEventPayload([{role: ai:USER, content: "found me"}])
    ];
    ai:ChatMessage[] decoded = <ai:ChatMessage[]>decodeEventPayload(payload);
    test:assertEquals(decoded.length(), 1);
    test:assertEquals(userContent(decoded[0]), "found me");
}

isolated function conversationalItemsOf(json[] payload) returns map<json>[] {
    map<json>[] items = [];
    foreach json item in payload {
        if item is map<json> && item.hasKey("conversational") {
            items.push(<map<json>>item["conversational"]);
        }
    }
    return items;
}

isolated function conversationalRoles(json[] payload) returns string[] =>
    from map<json> item in conversationalItemsOf(payload)
    select <string>item["role"];

isolated function conversationalTexts(json[] payload) returns string[] =>
    from map<json> item in conversationalItemsOf(payload)
    select <string>(<map<json>>item["content"])["text"];
