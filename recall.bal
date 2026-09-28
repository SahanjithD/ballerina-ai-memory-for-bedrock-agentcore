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

// A distinguishable name for the synthetic message this module appends, so it is recognizable in
// logs/traces as this module's own addition rather than a stored message.
const string RECALL_MESSAGE_NAME = "long_term_memory";

# Wraps an `ai:Memory` to additionally search long-term memory on every `get` call and append the
# results as an extra message, as an alternative to the tool-based `LongTermMemoryToolKit` that
# lets the LLM decide when to search.
#
# **This is off by default; construct it explicitly to opt in.** Injection runs unconditionally on
# every turn, at some latency and `RetrieveMemoryRecords` cost even when the LLM would not have
# needed it. Two narrower limitations, both inherent to hooking `ai:Memory.get` (the only hook
# `ai:Memory` offers) rather than bugs to work around:
#
# - The query searched is the *last stored* user message, not the query for the turn currently
# being run - `get(sessionId)` is called before `ai:Agent` appends the new query to history, and
# `ai:Memory`'s interface gives `get` no way to see it. Recall is therefore always one turn behind.
# - The appended message is **not** persisted: `ai:Agent` only ever writes back
# `[systemMessage, userMessage, ...toolPairs, finalAssistantMessage]` for the *current* turn (see
# the package's design notes), so this module's addition is naturally absent from what
# `self.delegate.update` is later called with - it is recomputed fresh on every `get` instead of
# accumulating in storage. That is intentional, not a bug: a fact search result is a point-in-time
# retrieval that should refresh every turn, and stale copies of it should not pile up in history.
#
# This module does not touch the system message: earlier revisions tried augmenting it in place,
# but `ai:Agent` 1.15.0 unconditionally recomputes `history[0]` from its own configured
# `instruction` on every run, discarding anything else stored there - so that approach silently
# had no effect at all. Appending a new message instead survives, because `ai:Agent` only ever
# rewrites index `0`.
public isolated class RecallAugmentedMemory {
    *ai:Memory;

    private final ai:Memory delegate;
    private final MemoryClient agentCoreClient;
    private final string memoryId;
    private final string[] & readonly namespaceTemplates;
    private final map<string> & readonly namespaceVariables;
    private final int topK;

    # Initializes the wrapper.
    #
    # + delegate - The underlying `ai:Memory` (typically an `agentcore:Memory`) to delegate
    # storage to; only `get` behavior is augmented
    # + connectionConfig - The AWS connection configuration
    # + memoryId - The identifier of the AgentCore Memory resource to search - the plain id, not
    # the full ARN (see `MemoryConfig.memoryId`'s documentation for why)
    # + config - The namespaces/variables/topK to search with, in the same shape
    # `LongTermMemoryToolKit` uses
    # + return - An `Error` if the underlying client fails to initialize or `config` is invalid
    public isolated function init(ai:Memory delegate, ConnectionConfig connectionConfig, string memoryId,
            *LongTermMemoryToolKitConfig config) returns Error? {
        if config.namespaces.length() == 0 {
            return error Error("RecallAugmentedMemory requires at least one namespace.");
        }
        if config.topK < 1 || config.topK > MAX_PAGE_SIZE {
            return error Error(string `Invalid topK: '${config.topK}'. Must be between 1 and ${MAX_PAGE_SIZE}.`);
        }
        MemoryClient|Error agentCoreClient = new (connectionConfig);
        if agentCoreClient is Error {
            return agentCoreClient;
        }
        self.delegate = delegate;
        self.agentCoreClient = agentCoreClient;
        self.memoryId = memoryId;
        self.namespaceTemplates = config.namespaces.cloneReadOnly();
        self.namespaceVariables = config.namespaceVariables.cloneReadOnly();
        self.topK = config.topK;
    }

    # Retrieves the delegate's stored messages, with a long-term memory search result appended as
    # an extra trailing message when a query and matching records can be found. Never appends to
    # an empty history - see the class documentation for why an empty array is a hazard, not just
    # a no-op, for anything that lands at index `0`.
    #
    # + sessionId - The session key
    # + return - The (possibly augmented) messages, or an `ai:MemoryError`
    public isolated function get(string sessionId) returns ai:ChatMessage[]|ai:MemoryError {
        ai:ChatMessage[] messages = check self.delegate.get(sessionId);
        if messages.length() == 0 {
            return messages;
        }

        string? query = lastUserQueryText(messages);
        if query is () {
            return messages;
        }

        MemoryRecordMatch[]|Error records = self.recall(query);
        if records is Error {
            log:printWarn("Recall injection failed; returning unaugmented memory.", records, sessionId = sessionId);
            return messages;
        }
        if records.length() == 0 {
            return messages;
        }

        // A new array, not a mutation of `messages` in place: `messages` may be a reference into
        // the delegate's own internal state (true of some `ai:Memory` implementations, though not
        // `agentcore:Memory`, which always allocates a fresh array per `get`), and this wrapper
        // must not corrupt it.
        return [...messages, buildRecallMessage(records)];
    }

    # Delegates unchanged to the wrapped `ai:Memory`.
    #
    # + sessionId - The session key
    # + message - The message or messages that make up the turn
    # + return - `()` on success, or an `ai:MemoryError`
    public isolated function update(string sessionId, ai:ChatMessage|ai:ChatMessage[] message) returns ai:MemoryError? {
        return self.delegate.update(sessionId, message);
    }

    # Delegates unchanged to the wrapped `ai:Memory`.
    #
    # + sessionId - The session key
    # + return - `()` on success, or an `ai:MemoryError`
    public isolated function delete(string sessionId) returns ai:MemoryError? {
        return self.delegate.delete(sessionId);
    }

    # Releases the resources held by this wrapper's own search client. Does not close the
    # delegate; the caller that constructed the delegate owns it.
    #
    # + return - An `Error` if releasing resources fails, or `()`
    public isolated function close() returns Error? {
        return self.agentCoreClient.close();
    }

    private isolated function recall(string query) returns MemoryRecordMatch[]|Error {
        MemoryRecordMatch[] merged = [];
        foreach string template in self.namespaceTemplates {
            string namespace = check resolveNamespace(template, self.namespaceVariables);
            RetrieveMemoryRecordsResponse page =
                check self.agentCoreClient->retrieveMemoryRecords(self.memoryId, namespace, query, self.topK);
            foreach MemoryRecordSummary summary in page.memoryRecordSummaries {
                merged.push(toMemoryRecordMatch(summary));
            }
        }
        MemoryRecordMatch[] sorted = from MemoryRecordMatch 'match in merged
            let float sortScore = 'match.score ?: 0.0
            order by sortScore descending
            select 'match;
        if sorted.length() > self.topK {
            sorted = sorted.slice(0, self.topK);
        }
        return sorted;
    }
}

isolated function lastUserQueryText(ai:ChatMessage[] messages) returns string? {
    int i = messages.length() - 1;
    while i >= 0 {
        ai:ChatMessage message = messages[i];
        if message is ai:ChatUserMessage {
            return renderContent(message.content);
        }
        i -= 1;
    }
    return ();
}

isolated function buildRecallMessage(MemoryRecordMatch[] records) returns ai:ChatSystemMessage {
    string block = "Relevant long-term memory:\n";
    foreach MemoryRecordMatch m in records {
        block += string `- ${m.text}` + "\n";
    }
    return {role: ai:SYSTEM, content: block, name: RECALL_MESSAGE_NAME};
}
