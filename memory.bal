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
import ballerina/time;

# An `ai:Memory` implementation backed by Amazon Bedrock AgentCore Memory. Each `update` call
# (one per agent turn) is stored as a single AgentCore event carrying the whole turn losslessly;
# `get` reads every event for the session back and folds them into one message list. Pending
# human-in-the-loop approvals are persisted in AgentCore too, so a paused run survives a restart
# or resumes on another replica. See the package's design notes for the rationale.
@display {label: "Amazon Bedrock AgentCore Memory"}
public isolated class Memory {
    *ai:Memory;

    private final MemoryClient agentCoreClient;
    private final string memoryId;
    private final SessionKeyConfig & readonly sessionKeyConfig;
    private final DeleteMode deleteMode;
    private final int maxEventsPerGet;
    private decimal lastEventTimestamp = 0d;

    # Initializes the memory.
    #
    # + config - The memory configuration
    # + return - An `Error` if the underlying client fails to initialize, if `verifyMemory` is
    # `true` and the configured `memoryId` cannot be confirmed active, or if `config` is otherwise
    # invalid
    public isolated function init(@display {label: "Memory Configuration"} MemoryConfig config) returns Error? {
        if config.maxEventsPerGet < 1 || config.maxEventsPerGet > MAX_PAGE_SIZE {
            return error Error(string `Invalid maxEventsPerGet: '${config.maxEventsPerGet}'. ` +
                string `Must be between 1 and ${MAX_PAGE_SIZE}.`);
        }
        self.memoryId = config.memoryId;
        self.sessionKeyConfig = config.sessionKeyConfig.cloneReadOnly();
        self.deleteMode = config.deleteMode;
        self.maxEventsPerGet = config.maxEventsPerGet;

        ConnectionConfig connectionConfig = {
            region: config.region,
            auth: config.auth,
            endpointConfig: config.endpointConfig,
            httpConfig: config.httpConfig
        };
        MemoryClient|Error agentCoreClient = new (connectionConfig);
        if agentCoreClient is Error {
            return agentCoreClient;
        }
        self.agentCoreClient = agentCoreClient;

        if config.verifyMemory {
            ControlPlaneMemory|Error memoryDetails = self.agentCoreClient->getMemory(config.memoryId);
            if memoryDetails is Error {
                return error Error(string `Failed to verify the AgentCore Memory resource '${config.memoryId}': ` +
                    memoryDetails.message(), memoryDetails);
            }
            if memoryDetails.status != "ACTIVE" {
                return error Error(string `The AgentCore Memory resource '${config.memoryId}' is not active ` +
                    string `(status: '${memoryDetails.status}').`);
            }
        }
    }

    # Retrieves every stored chat message for a session, in chronological order, with at most one
    # system message (the most recently written one - see the package's design notes on why
    # `ai:Agent` resends the system message every turn).
    #
    # + sessionId - The session key
    # + return - The session's messages, or an `ai:MemoryError`
    public isolated function get(string sessionId) returns ai:ChatMessage[]|ai:MemoryError {
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("get", sessionId);
        ai:ChatMessage[]|Error result =
            readSession(self.agentCoreClient, self.memoryId, actorId, agentSessionId, self.maxEventsPerGet);
        logIfFailed("get", sessionId, result);
        return result;
    }

    # Stores one turn's messages as a single AgentCore event.
    #
    # + sessionId - The session key
    # + message - The message or messages that make up the turn
    # + return - `()` on success, or an `ai:MemoryError`
    public isolated function update(string sessionId, ai:ChatMessage|ai:ChatMessage[] message) returns ai:MemoryError? {
        ai:ChatMessage[] messages = message is ai:ChatMessage[] ? message : [message];
        if messages.length() == 0 {
            return;
        }
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("update", sessionId);
        decimal eventTimestamp = self.nextEventTimestamp();
        Error? result = writeTurn(self.agentCoreClient, self.memoryId, actorId, agentSessionId, messages, eventTimestamp);
        logIfFailed("update", sessionId, result);
        return result;
    }

    # Deletes a session's history, per the configured `DeleteMode`, along with any pending
    # human-in-the-loop approval for the session, so an abandoned pause does not keep its history
    # snapshot around. The history and checkpoint removals are separate AgentCore calls and are not
    # atomic; if the checkpoint removal fails, the error is returned and it can be retried.
    #
    # + sessionId - The session key
    # + return - `()` on success, or an `ai:MemoryError`
    public isolated function delete(string sessionId) returns ai:MemoryError? {
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("delete", sessionId);
        decimal eventTimestamp = self.nextEventTimestamp();
        Error? result;
        if self.deleteMode == SOFT {
            result = writeResetMarker(self.agentCoreClient, self.memoryId, actorId, agentSessionId, eventTimestamp);
        } else {
            result = purgeSession(self.agentCoreClient, self.memoryId, actorId, agentSessionId, eventTimestamp);
        }
        if result is () {
            result = clearCheckpoint(self.agentCoreClient, self.memoryId, actorId, checkpointSessionId(agentSessionId));
        }
        logIfFailed("delete", sessionId, result);
        return result;
    }

    # Stores (or replaces) the pending human-in-the-loop approval for its session.
    #
    # + approval - The pending approval to persist
    # + return - `()` on success, or an `Error`
    public isolated function putCheckpoint(ai:PendingApproval approval) returns Error? {
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("putCheckpoint", approval.sessionId);
        decimal eventTimestamp = self.nextEventTimestamp();
        Error? result = writeCheckpoint(self.agentCoreClient, self.memoryId, actorId,
            checkpointSessionId(agentSessionId), approval, eventTimestamp);
        logIfFailed("putCheckpoint", approval.sessionId, result);
        return result;
    }

    # Returns the pending human-in-the-loop approval for a session, if any.
    #
    # + sessionId - The session key
    # + return - The pending approval, `()` if none is pending, or an `Error`
    public isolated function getCheckpoint(string sessionId) returns ai:PendingApproval?|Error {
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("getCheckpoint", sessionId);
        ai:PendingApproval?|Error result =
            readCheckpoint(self.agentCoreClient, self.memoryId, actorId, checkpointSessionId(agentSessionId));
        logIfFailed("getCheckpoint", sessionId, result);
        return result;
    }

    # Removes the pending human-in-the-loop approval for a session, if any.
    #
    # + sessionId - The session key
    # + return - `()` on success, or an `Error`
    public isolated function removeCheckpoint(string sessionId) returns Error? {
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("removeCheckpoint", sessionId);
        Error? result = clearCheckpoint(self.agentCoreClient, self.memoryId, actorId, checkpointSessionId(agentSessionId));
        logIfFailed("removeCheckpoint", sessionId, result);
        return result;
    }

    # Fetches and removes the pending human-in-the-loop approval for a session, if any, so that of
    # several concurrent resumes for the same session only one can claim it (see `checkpoint.bal`
    # for how the claim works and its one known gap).
    #
    # + sessionId - The session key
    # + return - The claimed pending approval, `()` if none was pending or another caller claimed
    # it first, or an `Error`
    public isolated function takeCheckpoint(string sessionId) returns ai:PendingApproval?|Error {
        [string, string] [actorId, agentSessionId] = check self.resolveKeys("takeCheckpoint", sessionId);
        ai:PendingApproval?|Error result =
            claimCheckpoint(self.agentCoreClient, self.memoryId, actorId, checkpointSessionId(agentSessionId));
        logIfFailed("takeCheckpoint", sessionId, result);
        return result;
    }

    # Releases the resources held by this memory's underlying `MemoryClient`.
    #
    # + return - An `Error` if releasing resources fails, or `()`
    public isolated function close() returns Error? {
        return self.agentCoreClient.close();
    }

    private isolated function resolveKeys(string operation, string sessionId) returns [string, string]|Error {
        [string, string]|Error keys = resolveSessionKey(self.sessionKeyConfig, sessionId);
        logIfFailed(operation, sessionId, keys);
        return keys;
    }

    // AgentCore's `eventTimestamp` is client-supplied and `ListEvents` documents no ordering
    // guarantee, so this module treats it as the primary sort key for folding a session's events
    // back into order (see `memory_read.bal`) and guards it against going backwards or colliding
    // within a single `Memory` instance - e.g. two turns completing within the same wall-clock
    // tick. This is a best-effort guard, not a distributed guarantee: it says nothing about
    // ordering across multiple `Memory` instances (processes/replicas) writing the same session
    // concurrently.
    private isolated function nextEventTimestamp() returns decimal {
        decimal candidate = toWireTimestamp(time:utcNow());
        lock {
            if candidate <= self.lastEventTimestamp {
                candidate = self.lastEventTimestamp + 0.000001d;
            }
            self.lastEventTimestamp = candidate;
            return candidate;
        }
    }
}
