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
import ballerina/log;

// Every `CreateEvent` this module issues carries exactly one `blob` payload item (the lossless,
// round-trippable envelope of the whole turn) plus zero or more `conversational` items rendered
// as plain text for AWS's own extraction strategies. `get` only ever decodes the blob items; the
// conversational items are write-only from this module's perspective. This is the "one event per
// turn, blob not extracted" design (see the package's design notes).
const int ENVELOPE_VERSION = 1;

// Marks a blob envelope as a soft-delete reset marker: `memory_read.bal` treats every event at or
// before a reset marker as void when folding a session's history back into a message list.
type EnvelopeBlob record {|
    int v = ENVELOPE_VERSION;
    boolean reset = false;
    DatabaseMessage[] messages;
|};

# Builds the `payload` array for one `CreateEvent` call representing a single agent turn.
#
# + messages - The full message set for the turn (as passed to `ai:Memory.update`)
# + return - The payload items: one `blob` item carrying every message losslessly, plus up to
# `MAX_CONVERSATIONAL_ITEMS_PER_EVENT` `conversational` items rendered from the non-system
# messages that have renderable text content
isolated function buildEventPayload(ai:ChatMessage[] messages) returns json[] {
    DatabaseMessage[] stored = from ai:ChatMessage message in messages select toDatabaseMessage(message);
    EnvelopeBlob blob = {messages: stored};
    json[] payload = [{blob: blob.toJson()}];
    payload.push(...conversationalItems(messages));
    return payload;
}

# Builds the `payload` array for a soft-delete reset marker event: a single blob item with no
# messages, flagged `reset: true`.
#
# + return - The single-item payload array for the reset marker event
isolated function buildResetMarkerPayload() returns json[] {
    EnvelopeBlob blob = {reset: true, messages: []};
    return [{blob: blob.toJson()}];
}

isolated function conversationalItems(ai:ChatMessage[] messages) returns json[] {
    json[] items = [];
    foreach ai:ChatMessage message in messages {
        [string, string]? rendered = renderConversationalItem(message);
        if rendered is [string, string] {
            var [role, text] = rendered;
            items.push({conversational: {content: {text}, role}});
        }
    }
    if items.length() > MAX_CONVERSATIONAL_ITEMS_PER_EVENT {
        log:printWarn("Turn produced more conversational items than a single AgentCore event can carry; " +
            "truncating. The full turn is still preserved losslessly in the event's blob item.",
            renderedCount = items.length(), keptCount = MAX_CONVERSATIONAL_ITEMS_PER_EVENT);
        items = items.slice(0, MAX_CONVERSATIONAL_ITEMS_PER_EVENT);
    }
    return items;
}

// The system message is deliberately never rendered as a conversational item: `ai:Agent` resends
// it in full on every turn (see the package's design notes), so rendering it every time would
// both repeat the same content into AWS's extraction pipeline on every turn and risk leaking
// instruction text into "conversation" search results. Assistant/function messages with no
// textual content (a pure tool call, or a tool result with no text) have nothing to render.
isolated function renderConversationalItem(ai:ChatMessage message) returns [string, string]? {
    if message is ai:ChatUserMessage {
        return [ROLE_USER, renderContent(message.content)];
    }
    if message is ai:ChatAssistantMessage {
        string? content = message.content;
        if content is string {
            return [ROLE_ASSISTANT, content];
        }
        return ();
    }
    if message is ai:ChatFunctionMessage {
        string? content = message.content;
        if content is string {
            return [ROLE_TOOL, content];
        }
        return ();
    }
    // ai:ChatSystemMessage
    return ();
}

# Decodes the messages of a single event from its `payload` array, i.e. the messages passed to the
# `ai:Memory.update` call that produced it.
#
# + payload - The event's payload array, as returned by `ListEvents`/`CreateEvent`
# + return - `()` if the payload carries no blob item (not an event this module wrote, or a
# payload fetched with `includePayloads: false`); otherwise the decoded turn - empty for a
# soft-delete reset marker - or an `Error` if the blob item cannot be decoded
isolated function decodeEventPayload(json[] payload) returns ai:ChatMessage[]|Error? {
    EnvelopeBlob? blob = check findBlob(payload);
    if blob is () {
        return ();
    }
    return from DatabaseMessage stored in blob.messages select fromDatabaseMessage(stored);
}

# Returns whether the event's payload carries a soft-delete reset marker blob.
#
# + payload - The event's payload array
# + return - `true` if the payload's blob item is a reset marker, `false` otherwise (including
# when there is no blob item), or an `Error` if the blob item cannot be decoded
isolated function isResetMarker(json[] payload) returns boolean|Error {
    EnvelopeBlob? blob = check findBlob(payload);
    return blob is EnvelopeBlob && blob.reset;
}

isolated function findBlob(json[] payload) returns EnvelopeBlob?|Error {
    foreach json item in payload {
        if item is map<json> {
            json? blobJson = item["blob"];
            if blobJson is () {
                continue;
            }
            EnvelopeBlob|error blob = blobJson.fromJsonWithType();
            if blob is error {
                return error Error("Failed to decode an AgentCore event's blob envelope: " + blob.message(), blob);
            }
            return blob;
        }
    }
    return ();
}
