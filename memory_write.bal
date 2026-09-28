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
import ballerina/lang.runtime;
import ballerina/log;
import ballerina/time;

// Client-side rate limit for physical-delete `DeleteEvent` calls, comfortably under the account
// quota (20 TPS/account) so a session purge never starves other sessions'/instances' deletes
// sharing the same AWS account.
const decimal DELETE_EVENT_RATE_LIMIT_INTERVAL_SECONDS = 0.25;

isolated function writeTurn(MemoryClient agentCoreClient, string memoryId, string actorId, string sessionId,
        ai:ChatMessage[] messages, decimal eventTimestamp) returns Error? {
    json[] payload = buildEventPayload(messages);
    _ = check agentCoreClient->createEvent(memoryId, actorId, sessionId, fromWireTimestamp(eventTimestamp), payload);
}

isolated function writeResetMarker(MemoryClient agentCoreClient, string memoryId, string actorId, string sessionId,
        decimal eventTimestamp) returns Error? {
    json[] payload = buildResetMarkerPayload();
    _ = check agentCoreClient->createEvent(memoryId, actorId, sessionId, fromWireTimestamp(eventTimestamp), payload);
}

// `PHYSICAL` delete first writes a reset marker (so `get` reads as empty immediately, without
// waiting on the purge below) and then removes every prior event individually, rate-limited.
// AWS documents no atomicity for a batch of `DeleteEvent` calls, so a purge interrupted midway
// leaves some prior events physically removed and others not - `get` is unaffected either way,
// since the reset marker alone already makes it read as empty.
isolated function purgeSession(MemoryClient agentCoreClient, string memoryId, string actorId, string sessionId)
        returns Error? {
    json[] resetPayload = buildResetMarkerPayload();
    _ = check agentCoreClient->createEvent(memoryId, actorId, sessionId, time:utcNow(), resetPayload);

    string? nextToken = ();
    boolean firstPage = true;
    while firstPage || nextToken is string {
        firstPage = false;
        ListEventsResponse page = check agentCoreClient->listEvents(memoryId, actorId, sessionId, MAX_PAGE_SIZE,
            nextToken);
        foreach WireEvent event in page.events {
            string|Error deleted = agentCoreClient->deleteEvent(memoryId, actorId, sessionId, event.eventId);
            if deleted is Error {
                log:printWarn("Failed to physically delete an AgentCore event during a session purge; " +
                    "the session still reads as empty because of the reset marker.",
                    deleted, memoryId = memoryId, eventId = event.eventId);
            }
            runtime:sleep(DELETE_EVENT_RATE_LIMIT_INTERVAL_SECONDS);
        }
        nextToken = page.nextToken;
    }
}
