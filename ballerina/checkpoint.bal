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
import ballerina/crypto;
import ballerina/log;
import ballerina/time;

// A session's human-in-the-loop checkpoint lives in its own AgentCore session under the same
// actor, derived from (but never equal to) the conversation session: `get`'s single `ListEvents`
// page is never spent on checkpoint events, and checkpoint state can never be mistaken for a turn
// or a reset marker. The prefix is reserved - `resolveSessionKey` rejects any session key that
// would itself resolve to a session id starting with it. `"ckpt--"` plus a 64-character hex
// digest is 70 characters, inside AgentCore's 100-character `sessionId` limit and pattern.
const string CHECKPOINT_SESSION_PREFIX = "ckpt--";
const string CHECKPOINT_KIND = "checkpoint";

isolated function checkpointSessionId(string agentSessionId) returns string =>
    CHECKPOINT_SESSION_PREFIX + crypto:hashSha256(agentSessionId.toBytes()).toBase16();

// JSON-safe forms of `ai:Iteration`/`ai:PendingApproval`: `history` uses `DatabaseMessage` for the
// same reason the turn envelope does (`ai:Prompt` content is not JSON-serializable), and an
// iteration `output` that is an `ai:Error` is narrowed to its message, since error values are not
// serializable either - the same convention `ballerina/ai`'s own in-memory store applies.
type StoredIteration record {|
    DatabaseMessage[] history;
    (ai:ChatAssistantMessage|ai:ChatFunctionMessage|string)[] output;
    time:Utc startTime;
    time:Utc endTime;
|};

type StoredApproval record {|
    string sessionId;
    string executionId;
    int iterationsUsed;
    DatabaseMessage[] history;
    int historyPrefixLength;
    StoredIteration[] iterations;
    ai:FunctionCall[] toolCalls;
    time:Utc startTime;
    ai:FunctionCall[] originalBatch;
    ai:ApprovalRequest[] pendingRequests;
    ai:HumanDecision?[] decisions;
|};

type CheckpointBlob record {
    int v = ENVELOPE_VERSION;
    string kind = CHECKPOINT_KIND;
    StoredApproval approval;
};

isolated function toStoredApproval(ai:PendingApproval approval) returns StoredApproval => {
    sessionId: approval.sessionId,
    executionId: approval.executionId,
    iterationsUsed: approval.iterationsUsed,
    history: from ai:ChatMessage message in approval.history select toDatabaseMessage(message),
    historyPrefixLength: approval.historyPrefixLength,
    iterations: from ai:Iteration iteration in approval.iterations select toStoredIteration(iteration),
    toolCalls: approval.toolCalls,
    startTime: approval.startTime,
    originalBatch: approval.originalBatch,
    pendingRequests: approval.pendingRequests,
    decisions: approval.decisions
};

isolated function fromStoredApproval(StoredApproval stored) returns ai:PendingApproval => {
    sessionId: stored.sessionId,
    executionId: stored.executionId,
    iterationsUsed: stored.iterationsUsed,
    history: from DatabaseMessage message in stored.history select fromDatabaseMessage(message),
    historyPrefixLength: stored.historyPrefixLength,
    iterations: from StoredIteration iteration in stored.iterations select fromStoredIteration(iteration),
    toolCalls: stored.toolCalls,
    startTime: stored.startTime,
    originalBatch: stored.originalBatch,
    pendingRequests: stored.pendingRequests,
    decisions: stored.decisions
};

isolated function toStoredIteration(ai:Iteration iteration) returns StoredIteration => {
    history: from ai:ChatMessage message in iteration.history select toDatabaseMessage(message),
    output: from var output in iteration.output select toStoredOutput(output),
    startTime: iteration.startTime,
    endTime: iteration.endTime
};

isolated function fromStoredIteration(StoredIteration stored) returns ai:Iteration => {
    history: from DatabaseMessage message in stored.history select fromDatabaseMessage(message),
    output: from var output in stored.output select fromStoredOutput(output),
    startTime: stored.startTime,
    endTime: stored.endTime
};

isolated function toStoredOutput(ai:ChatAssistantMessage|ai:ChatFunctionMessage|ai:Error output)
        returns ai:ChatAssistantMessage|ai:ChatFunctionMessage|string {
    if output is ai:Error {
        error? cause = output.cause();
        return cause is error ? string `${output.message()} (cause: ${cause.message()})` : output.message();
    }
    return output;
}

isolated function fromStoredOutput(ai:ChatAssistantMessage|ai:ChatFunctionMessage|string stored)
        returns ai:ChatAssistantMessage|ai:ChatFunctionMessage|ai:Error =>
    stored is string ? error ai:Error(stored) : stored;

isolated function buildCheckpointPayload(ai:PendingApproval approval) returns json[] {
    CheckpointBlob blob = {approval: toStoredApproval(approval)};
    return [blobItem(blob.toJson())];
}

// Mirrors `findBlob`'s tolerance: a blob that is not recognizably this build's checkpoint (another
// writer, or a different envelope version) is skipped, never treated as fatal.
isolated function decodeCheckpoint(json[] payload) returns ai:PendingApproval? {
    foreach json item in payload {
        map<json>? blobJson = blobDocument(item);
        if blobJson is () || blobJson["v"] != ENVELOPE_VERSION || blobJson["kind"] != CHECKPOINT_KIND {
            continue;
        }
        CheckpointBlob|error blob = blobJson.fromJsonWithType();
        if blob is error {
            log:printWarn("Skipping an AgentCore checkpoint event that failed to decode.", blob);
            continue;
        }
        return fromStoredApproval(blob.approval);
    }
    return ();
}

isolated function listCheckpointEvents(MemoryClient agentCoreClient, string memoryId, string actorId,
        string checkpointSession) returns WireEvent[]|Error {
    ListEventsResponse page = check agentCoreClient->listEvents(memoryId, actorId, checkpointSession, MAX_PAGE_SIZE);
    return sortEventsChronologically(page.events);
}

isolated function latestCheckpoint(WireEvent[] chronological) returns [WireEvent, ai:PendingApproval]? {
    int i = chronological.length() - 1;
    while i >= 0 {
        ai:PendingApproval? approval = decodeCheckpoint(chronological[i].payload);
        if approval is ai:PendingApproval {
            return [chronological[i], approval];
        }
        i -= 1;
    }
    return ();
}

// Replace semantics on an append-only log: write the new checkpoint first, then remove every
// other checkpoint event, so there is never a moment with no checkpoint stored. A failure to
// remove an older one is returned rather than swallowed - left behind, it could resurface as the
// "latest" checkpoint after the new one is taken.
isolated function writeCheckpoint(MemoryClient agentCoreClient, string memoryId, string actorId,
        string checkpointSession, ai:PendingApproval approval, decimal eventTimestamp) returns Error? {
    WireEvent written = check agentCoreClient->createEvent(memoryId, actorId, checkpointSession,
        fromWireTimestamp(eventTimestamp), buildCheckpointPayload(approval));
    WireEvent[] events = check listCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession);
    check deleteCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession,
        from WireEvent event in events where event.eventId != written.eventId select event);
}

isolated function readCheckpoint(MemoryClient agentCoreClient, string memoryId, string actorId,
        string checkpointSession) returns ai:PendingApproval?|Error {
    WireEvent[] events = check listCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession);
    [WireEvent, ai:PendingApproval]? latest = latestCheckpoint(events);
    return latest is () ? () : latest[1];
}

isolated function clearCheckpoint(MemoryClient agentCoreClient, string memoryId, string actorId,
        string checkpointSession) returns Error? {
    WireEvent[] events = check listCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession);
    check deleteCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession, events);
}

// The claim is the `DeleteEvent` of the latest checkpoint event itself: of several concurrent
// callers that all read the same checkpoint, only the one whose delete succeeds gets it back;
// the rest see 404 and return `()`, so an approved tool call cannot run twice. This relies on
// `DeleteEvent` being linearizable per event, which AWS does not document either way - it is one
// of this package's outstanding live checks. One known gap: if a claiming delete succeeds
// server-side but its response is lost, the client's retry sees 404 and reports "nothing to
// claim", losing that pause.
isolated function claimCheckpoint(MemoryClient agentCoreClient, string memoryId, string actorId,
        string checkpointSession) returns ai:PendingApproval?|Error {
    WireEvent[] events = check listCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession);
    [WireEvent, ai:PendingApproval]? latest = latestCheckpoint(events);
    if latest is () {
        return ();
    }
    var [claimEvent, approval] = latest;
    // Stale leftovers go first, so a successful claim never leaves behind an older checkpoint a
    // later `getCheckpoint` could mistake for a live pause.
    check deleteCheckpointEvents(agentCoreClient, memoryId, actorId, checkpointSession,
        from WireEvent event in events where event.eventId != claimEvent.eventId select event);
    string|Error claimed = agentCoreClient->deleteEvent(memoryId, actorId, checkpointSession, claimEvent.eventId);
    if claimed is Error {
        return isNotFound(claimed) ? () : claimed;
    }
    return approval;
}

// A 404 means another caller removed the event first, which is the outcome being asked for.
isolated function deleteCheckpointEvents(MemoryClient agentCoreClient, string memoryId, string actorId,
        string checkpointSession, WireEvent[] events) returns Error? {
    foreach WireEvent event in events {
        string|Error deleted = agentCoreClient->deleteEvent(memoryId, actorId, checkpointSession, event.eventId);
        if deleted is Error && !isNotFound(deleted) {
            return deleted;
        }
    }
}

isolated function isNotFound(Error err) returns boolean => err.detail().httpStatusCode == 404;
