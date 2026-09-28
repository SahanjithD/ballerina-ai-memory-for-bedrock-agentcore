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
# `get` reads every event for the session back and folds them into one message list. See the
# package's design notes for the rationale.
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
    public isolated function init(MemoryConfig config) returns Error? {
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
        [string, string] keys = check resolveSessionKey(self.sessionKeyConfig, sessionId);
        var [actorId, agentSessionId] = keys;
        ai:ChatMessage[]|Error result =
            readSession(self.agentCoreClient, self.memoryId, actorId, agentSessionId, self.maxEventsPerGet);
        if result is Error {
            logAgentCoreFailure("get", sessionId, result);
        }
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
        [string, string] keys = check resolveSessionKey(self.sessionKeyConfig, sessionId);
        var [actorId, agentSessionId] = keys;
        decimal eventTimestamp = self.nextEventTimestamp();
        Error? result = writeTurn(self.agentCoreClient, self.memoryId, actorId, agentSessionId, messages, eventTimestamp);
        if result is Error {
            logAgentCoreFailure("update", sessionId, result);
        }
        return result;
    }

    # Deletes a session's history, per the configured `DeleteMode`.
    #
    # + sessionId - The session key
    # + return - `()` on success, or an `ai:MemoryError`
    public isolated function delete(string sessionId) returns ai:MemoryError? {
        [string, string] keys = check resolveSessionKey(self.sessionKeyConfig, sessionId);
        var [actorId, agentSessionId] = keys;
        Error? result;
        if self.deleteMode == SOFT {
            decimal eventTimestamp = self.nextEventTimestamp();
            result = writeResetMarker(self.agentCoreClient, self.memoryId, actorId, agentSessionId, eventTimestamp);
        } else {
            result = purgeSession(self.agentCoreClient, self.memoryId, actorId, agentSessionId);
        }
        if result is Error {
            logAgentCoreFailure("delete", sessionId, result);
        }
        return result;
    }

    # Releases the resources held by this memory's underlying `MemoryClient`.
    #
    # + return - An `Error` if releasing resources fails, or `()`
    public isolated function close() returns Error? {
        return self.agentCoreClient.close();
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
