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

// A purge round-trips at most this many `ListEvents`-then-delete rounds before giving up. A
// session has at most 100 events per page and this allows 50 rounds (5,000 events) of purging -
// generous for any real conversation history - while still bounding a pathological case (e.g. a
// missing `DeleteEvent` IAM permission, where every attempt fails and events never shrink) to a
// finite amount of work instead of looping forever.
const int MAX_PURGE_ROUNDS = 50;

// `PHYSICAL` delete first writes a reset marker (so `get` reads as empty immediately, without
// waiting on the purge below) and then removes every prior event, rate-limited. The marker itself
// is excluded from deletion: it is now an event of this session too, and deleting it along with
// everything else would mean a purge that fails partway through (a throttled `ListEvents`, a
// transient 5xx) leaves the session with *no* reset marker and only some events physically gone -
// silently resurrecting the remaining "deleted" history on the next `get`. Each round re-lists
// from scratch (no `nextToken` chaining) rather than paginating through a set that is being
// mutated out from under it, since AWS documents no stability guarantee for a token once the
// events it was minted against start changing.
isolated function purgeSession(MemoryClient agentCoreClient, string memoryId, string actorId, string sessionId,
        decimal eventTimestamp) returns Error? {
    json[] resetPayload = buildResetMarkerPayload();
    WireEvent marker =
        check agentCoreClient->createEvent(memoryId, actorId, sessionId, fromWireTimestamp(eventTimestamp), resetPayload);

    foreach int _ in 0 ..< MAX_PURGE_ROUNDS {
        ListEventsResponse page = check agentCoreClient->listEvents(memoryId, actorId, sessionId, MAX_PAGE_SIZE);
        WireEvent[] toDelete = from WireEvent event in page.events
            where event.eventId != marker.eventId
            select event;
        if toDelete.length() == 0 {
            return;
        }
        foreach WireEvent event in toDelete {
            string|Error deleted = agentCoreClient->deleteEvent(memoryId, actorId, sessionId, event.eventId);
            if deleted is Error {
                log:printWarn("Failed to physically delete an AgentCore event during a session purge; " +
                    "the session still reads as empty because of the reset marker.",
                    deleted, memoryId = memoryId, eventId = event.eventId);
            }
            runtime:sleep(DELETE_EVENT_RATE_LIMIT_INTERVAL_SECONDS);
        }
    }
    log:printWarn("Session purge did not finish physically deleting every event within the round budget; " +
        "the session still reads as empty because of the reset marker, but some prior events remain stored.",
        memoryId = memoryId, actorId = actorId, sessionId = sessionId, maxRounds = MAX_PURGE_ROUNDS);
}
