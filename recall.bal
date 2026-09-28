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

// Prefixes the block this module appends to the system message's content, so repeated injection
// across turns (each turn re-reads and re-augments the *stored* system message the delegate
// returns, never a previously-injected one) stays additive rather than compounding: the delegate
// always returns the plain stored message, since injection never itself calls `update`.
const string RECALL_BLOCK_HEADER = "\n\nRelevant long-term memory:\n";

# Wraps an `ai:Memory` to additionally search long-term memory on every `get` call and inject
# the results into the (existing) system message, as an alternative to the tool-based
# `LongTermMemoryToolKit` that lets the LLM decide when to search.
#
# **This is off by default; construct it explicitly to opt in.** Unlike the toolkit, injection
# runs unconditionally on every turn and its placement depends on `ai:Agent` always treating the
# first message `get` returns as the system message when one is present - true for `ai:Agent`
# 1.15.0's current prompt-assembly behavior, but not part of `ai:Memory`'s documented contract, so
# an upstream change could silently break the injected content's placement. On a session with no
# stored messages yet (nothing for `ai:Agent` to have derived a system message from), this wrapper
# deliberately injects nothing rather than inventing system-message content of its own; the empty
# array is returned unchanged.
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
    # + memoryId - The identifier (or ARN) of the AgentCore Memory resource to search
    # + config - The namespaces/variables/topK to search with, in the same shape
    # `LongTermMemoryToolKit` uses
    # + return - An `Error` if the underlying client fails to initialize or `config` is invalid
    public isolated function init(ai:Memory delegate, ConnectionConfig connectionConfig, string memoryId,
            *LongTermMemoryToolKitConfig config) returns Error? {
        if config.namespaces.length() == 0 {
            return error Error("RecallAugmentedMemory requires at least one namespace.");
        }
        if config.topK < 1 {
            return error Error(string `Invalid topK: '${config.topK}'. Must be a positive integer.`);
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

    # Retrieves the delegate's stored messages, with long-term memory results injected into the
    # system message when one is present and a query and matching records can be found.
    #
    # + sessionId - The session key
    # + return - The (possibly augmented) messages, or an `ai:MemoryError`
    public isolated function get(string sessionId) returns ai:ChatMessage[]|ai:MemoryError {
        ai:ChatMessage[] messages = check self.delegate.get(sessionId);
        if messages.length() == 0 {
            return messages;
        }

        ai:ChatMessage first = messages[0];
        if first !is ai:ChatSystemMessage {
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

        messages[0] = injectRecall(first, records);
        return messages;
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

isolated function injectRecall(ai:ChatSystemMessage systemMessage, MemoryRecordMatch[] records) returns ai:ChatSystemMessage {
    string|ai:Prompt content = systemMessage.content;
    if content !is string {
        // The system message uses a `Prompt` (raw template) content; injection only supports
        // plain-string system message content, so the message is returned unmodified.
        return systemMessage;
    }
    string block = RECALL_BLOCK_HEADER;
    foreach MemoryRecordMatch m in records {
        block += string `- ${m.text}` + "\n";
    }
    ai:ChatSystemMessage augmented = {role: systemMessage.role, content: content + block};
    string? name = systemMessage?.name;
    if name is string {
        augmented.name = name;
    }
    return augmented;
}
