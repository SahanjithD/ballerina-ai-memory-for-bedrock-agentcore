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

isolated function readSession(MemoryClient agentCoreClient, string memoryId, string actorId, string sessionId,
        int maxEventsPerGet) returns ai:ChatMessage[]|Error {
    WireEvent[] events = check fetchEvents(agentCoreClient, memoryId, actorId, sessionId, maxEventsPerGet);
    WireEvent[] ordered = sortEventsChronologically(events);
    WireEvent[] sinceReset = dropEventsAtOrBeforeLastResetMarker(ordered);
    return foldTurnsIntoMessages(sinceReset);
}

// `maxEventsPerGet` is validated (in `Memory.init`) to be at most `MAX_PAGE_SIZE`, so a session's
// events are always readable in a single `ListEvents` call - there is no pagination loop here to
// get wrong. If a session has more events than `maxEventsPerGet`, `ListEvents`' own undocumented
// ordering decides which ones come back; this module cannot fetch "the newest N" without reading
// every page first (defeating the point of a page-size cap), so that is a known v1 limitation of
// a plain `maxEventsPerGet`-bounded `get`, not something this function can paper over.
isolated function fetchEvents(MemoryClient agentCoreClient, string memoryId, string actorId, string sessionId,
        int maxEventsPerGet) returns WireEvent[]|Error {
    ListEventsResponse page = check agentCoreClient->listEvents(memoryId, actorId, sessionId, maxEventsPerGet);
    return page.events;
}

// Primary sort key is the client-supplied `eventTimestamp` (see `Memory`'s monotonic-timestamp
// guard); `eventId`'s numeric prefix is a stable tie-breaker for events sharing a timestamp.
isolated function sortEventsChronologically(WireEvent[] events) returns WireEvent[] =>
    from WireEvent event in events
    order by event.eventTimestamp ascending, eventSequenceNumber(event.eventId) ascending
    select event;

isolated function eventSequenceNumber(string eventId) returns int {
    int? hashIndex = eventId.indexOf("#");
    string numericPrefix = hashIndex is int ? eventId.substring(0, hashIndex) : eventId;
    int|error sequence = int:fromString(numericPrefix);
    return sequence is int ? sequence : 0;
}

// A soft `delete` writes a reset-marker event rather than physically removing prior events (see
// `memory_write.bal`); every event at or before the *last* reset marker is void.
isolated function dropEventsAtOrBeforeLastResetMarker(WireEvent[] chronological) returns WireEvent[] {
    int lastResetIndex = -1;
    foreach int i in 0 ..< chronological.length() {
        if isResetMarker(chronological[i].payload) {
            lastResetIndex = i;
        }
    }
    if lastResetIndex < 0 {
        return chronological;
    }
    return chronological.slice(lastResetIndex + 1);
}

// Each event's blob decodes to the exact message set passed to one `update` call, i.e. one whole
// agent turn: `[systemMessage, userMessage, ...toolCallPairs, finalAssistantMessage]` (see the
// package's design notes). `ai:Agent` resends the same system message on every turn, so it is
// deduplicated here to the most recently written one rather than accumulated once per turn.
isolated function foldTurnsIntoMessages(WireEvent[] events) returns ai:ChatMessage[] {
    ai:ChatSystemMessage? systemMessage = ();
    ai:ChatInteractiveMessage[] interactive = [];

    foreach WireEvent event in events {
        ai:ChatMessage[]? turnMessages = decodeEventPayload(event.payload);
        if turnMessages is () {
            continue;
        }
        foreach ai:ChatMessage message in turnMessages {
            if message is ai:ChatSystemMessage {
                systemMessage = message;
            } else {
                interactive.push(<ai:ChatInteractiveMessage>message);
            }
        }
    }

    ai:ChatMessage[] result = [];
    if systemMessage is ai:ChatSystemMessage {
        result.push(systemMessage);
    }
    result.push(...interactive);
    return result;
}
