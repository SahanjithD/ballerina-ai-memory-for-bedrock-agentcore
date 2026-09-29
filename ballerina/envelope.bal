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
//
// Deliberately an *open* record: the same AgentCore Memory resource can carry events from other
// writers (a future version of this module, or another SDK/framework entirely) whose `blob` item
// is not this shape at all. `findBlob` below treats anything that isn't recognizably "ours" -
// wrong/missing `v`, or a `messages` field that doesn't decode - as simply not an envelope this
// module can read, not as a fatal error for the whole session.
type EnvelopeBlob record {
    int v = ENVELOPE_VERSION;
    boolean reset = false;
    DatabaseMessage[] messages;
};

# Builds the `payload` array for one `CreateEvent` call representing a single agent turn.
#
# + messages - The full message set for the turn (as passed to `ai:Memory.update`)
# + return - The payload items: one `blob` item carrying every message losslessly, plus up to
# `MAX_CONVERSATIONAL_ITEMS_PER_EVENT` `conversational` items rendered from the non-system
# messages that have renderable text content
isolated function buildEventPayload(ai:ChatMessage[] messages) returns json[] {
    DatabaseMessage[] stored = from ai:ChatMessage message in messages select toDatabaseMessage(message);
    EnvelopeBlob blob = {messages: stored};
    json[] payload = [blobItem(blob.toJson())];
    payload.push(...conversationalItems(messages));
    return payload;
}

# Builds the `payload` array for a soft-delete reset marker event: a single blob item with no
# messages, flagged `reset: true`.
#
# + return - The single-item payload array for the reset marker event
isolated function buildResetMarkerPayload() returns json[] {
    EnvelopeBlob blob = {reset: true, messages: []};
    return [blobItem(blob.toJson())];
}

// AgentCore accepts a JSON object as a `blob`, but reads it back as a Java `Map.toString()` string
// (`{v=1, messages=[...]}`) that is no longer JSON. A JSON string round-trips byte for byte, so
// the blob is always written as JSON text and parsed on read.
isolated function blobItem(json document) returns json => {blob: document.toJsonString()};

// Returns the parsed document of a payload item's `blob`, or `()` if the item has no blob or its
// blob is not a JSON object encoded as a string.
isolated function blobDocument(json item) returns map<json>? {
    if item !is map<json> {
        return ();
    }
    json? blob = item["blob"];
    if blob !is string {
        return ();
    }
    json|error document = blob.fromJsonString();
    return document is map<json> ? document : ();
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
        return clampedConversationalItem(ROLE_USER, renderContent(message.content));
    }
    if message is ai:ChatAssistantMessage {
        string? content = message.content;
        if content is string {
            return clampedConversationalItem(ROLE_ASSISTANT, content);
        }
        return ();
    }
    if message is ai:ChatFunctionMessage {
        string? content = message.content;
        if content is string {
            return clampedConversationalItem(ROLE_TOOL, content);
        }
        return ();
    }
    // ai:ChatSystemMessage
    return ();
}

// `Content.text` requires 1-100,000 characters. An empty tool result (very common: many tools
// return "" on a no-op success) or an oversized one (a large HTTP/file-read result) would
// otherwise fail AWS's validation for the *whole event*, including the lossless blob item -
// silently losing the entire turn, since `ai:Agent` only logs `Memory.update` failures at debug
// level. Skipping/truncating here keeps that failure mode from ever reaching AWS.
isolated function clampedConversationalItem(string role, string text) returns [string, string]? {
    if text.length() == 0 {
        return ();
    }
    if text.length() > MAX_CONVERSATIONAL_TEXT_LENGTH {
        return [role, text.substring(0, MAX_CONVERSATIONAL_TEXT_LENGTH)];
    }
    return [role, text];
}

# Decodes the messages of a single event from its `payload` array, i.e. the messages passed to the
# `ai:Memory.update` call that produced it.
#
# + payload - The event's payload array, as returned by `ListEvents`/`CreateEvent`
# + return - `()` if the payload carries no blob item this module recognizes (not an event this
# module wrote, a payload fetched with `includePayloads: false`, or a blob item this build's
# `EnvelopeBlob` shape cannot decode - see `findBlob`); otherwise the decoded turn, empty for a
# soft-delete reset marker
isolated function decodeEventPayload(json[] payload) returns ai:ChatMessage[]? {
    EnvelopeBlob? blob = findBlob(payload);
    if blob is () {
        return ();
    }
    return from DatabaseMessage stored in blob.messages select fromDatabaseMessage(stored);
}

# Returns whether the event's payload carries a soft-delete reset marker blob.
#
# + payload - The event's payload array
# + return - `true` if the payload's blob item is a reset marker, `false` otherwise, including
# when there is no blob item this module recognizes
isolated function isResetMarker(json[] payload) returns boolean {
    EnvelopeBlob? blob = findBlob(payload);
    return blob is EnvelopeBlob && blob.reset;
}

// A session's events are not necessarily all written by this module: the same AgentCore Memory
// resource can be shared with another SDK/framework, or read by a future/older build of this
// module. A `blob` item that isn't recognizably one of *this* build's envelopes - wrong/missing
// `v`, or a shape `EnvelopeBlob` can't decode - is treated as "not ours" and skipped, rather than
// failing `get` for the whole session over one foreign or forward-incompatible event.
isolated function findBlob(json[] payload) returns EnvelopeBlob? {
    foreach json item in payload {
        map<json>? blobJson = blobDocument(item);
        if blobJson is () {
            continue;
        }
        json? versionField = blobJson["v"];
        if versionField != ENVELOPE_VERSION {
            continue;
        }
        EnvelopeBlob|error blob = blobJson.fromJsonWithType();
        if blob is error {
            log:printWarn("Skipping an AgentCore event blob item that looked like this module's " +
                "envelope (matching version) but failed to decode.", blob);
            continue;
        }
        return blob;
    }
    return ();
}
