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

type SearchMemoryInput record {|
    string query;
|};

# A tool-based long-term memory recall toolkit backed by AgentCore's `RetrieveMemoryRecords`.
# Exposes a single `searchMemory` tool the LLM can call explicitly, as an alternative to
# unconditional recall injection into every turn (see `recall.bal`) - the LLM decides when a
# lookup is worth the call.
public isolated class LongTermMemoryToolKit {
    *ai:BaseToolKit;

    private final MemoryClient agentCoreClient;
    private final string memoryId;
    private final string[] & readonly namespaceTemplates;
    private final map<string> & readonly namespaceVariables;
    private final int topK;
    private final ai:ToolConfig[] & readonly tools;

    # Initializes the toolkit.
    #
    # + connectionConfig - The AWS connection configuration
    # + memoryId - The identifier of the AgentCore Memory resource to search - the plain id, not
    # the full ARN (see `MemoryConfig.memoryId`'s documentation for why)
    # + config - The toolkit configuration
    # + return - An `Error` if the underlying client fails to initialize or `config` is invalid
    public isolated function init(ConnectionConfig connectionConfig, string memoryId,
            *LongTermMemoryToolKitConfig config) returns Error? {
        if config.namespaces.length() == 0 {
            return error Error("LongTermMemoryToolKit requires at least one namespace.");
        }
        if config.topK < 1 || config.topK > MAX_PAGE_SIZE {
            return error Error(string `Invalid topK: '${config.topK}'. Must be between 1 and ${MAX_PAGE_SIZE}.`);
        }

        MemoryClient|Error agentCoreClient = new (connectionConfig);
        if agentCoreClient is Error {
            return agentCoreClient;
        }
        self.agentCoreClient = agentCoreClient;
        self.memoryId = memoryId;
        self.namespaceTemplates = config.namespaces.cloneReadOnly();
        self.namespaceVariables = config.namespaceVariables.cloneReadOnly();
        self.topK = config.topK;

        isolated function (SearchMemoryInput) returns MemoryRecordMatch[]|Error caller = self.searchMemory;
        self.tools = [
            {
                name: config.toolName,
                description: config.toolDescription,
                parameters: {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "The natural-language query to search long-term memory for."
                        }
                    },
                    "required": ["query"]
                },
                caller
            }
        ];
    }

    # Returns this toolkit's tools, for registration with an `ai:Agent`.
    #
    # + return - An array containing the single `searchMemory` tool
    public isolated function getTools() returns ai:ToolConfig[] => self.tools;

    # Releases the resources held by this toolkit's underlying `MemoryClient` (its HTTP clients
    # and, unless an existing `auth:CredentialProvider` was passed in, its own credential
    # provider).
    #
    # + return - An `Error` if releasing resources fails, or `()`
    public isolated function close() returns Error? {
        return self.agentCoreClient.close();
    }

    # Searches every configured namespace for records relevant to `input.query`, merges the
    # results, and returns the top `topK` by score. Issues exactly one `RetrieveMemoryRecords`
    # call per namespace - no further pages are followed even if a namespace has more matches,
    # since retrieval is billed per call and the results are already re-sorted and truncated
    # client-side across namespaces.
    #
    # + input - The tool's input, as invoked by the LLM
    # + return - The merged, re-sorted, capped matches, or an `Error`
    isolated function searchMemory(SearchMemoryInput input) returns MemoryRecordMatch[]|Error {
        MemoryRecordMatch[] merged = [];
        foreach string template in self.namespaceTemplates {
            string namespace = check resolveNamespace(template, self.namespaceVariables);
            RetrieveMemoryRecordsResponse page =
                check self.agentCoreClient->retrieveMemoryRecords(self.memoryId, namespace, input.query, self.topK);
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

isolated function toMemoryRecordMatch(MemoryRecordSummary summary) returns MemoryRecordMatch {
    json? textField = summary.content["text"];
    string text = textField is string ? textField : "";
    return {
        text,
        score: summary?.score,
        namespaces: summary.namespaces.clone(),
        label: recordLabel(summary),
        createdAt: time:utcToString(fromWireTimestamp(summary.createdAt))
    };
}

// AWS currently caps `namespaces` at one entry per record (`NamespacesList` max: 1), so there is
// only ever one to pick from here, not a "most specific of several" choice - this labeling logic
// would need revisiting if AWS ever allows more.
isolated function recordLabel(MemoryRecordSummary summary) returns string {
    if summary.namespaces.length() == 0 {
        return summary.memoryRecordId;
    }
    string namespace = summary.namespaces[0];
    string[] segments = re `/`.split(namespace);
    string? lastNonEmpty = ();
    foreach string segment in segments {
        if segment.length() > 0 {
            lastNonEmpty = segment;
        }
    }
    return lastNonEmpty is string ? lastNonEmpty : namespace;
}
