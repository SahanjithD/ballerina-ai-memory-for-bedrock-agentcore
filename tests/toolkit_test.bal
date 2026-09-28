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
import ballerina/test;

@test:Config
function testToolkitExposesOneSearchTool() returns error? {
    resetMock();
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID, namespaces = ["/facts/user-42"]);

    ai:ToolConfig[] tools = toolkit.getTools();
    test:assertEquals(tools.length(), 1);
    test:assertEquals(tools[0].name, "search_long_term_memory");
    test:assertEquals(tools[0].parameters, {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "The natural-language query to search long-term memory for."}
        },
        "required": ["query"]
    });
    check toolkit.close();
}

@test:Config
function testToolNameAndDescriptionAreConfigurable() returns error? {
    resetMock();
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/user-42"], toolName = "recall", toolDescription = "Recalls facts.");

    test:assertEquals(toolkit.getTools()[0].name, "recall");
    test:assertEquals(toolkit.getTools()[0].description, "Recalls facts.");
    check toolkit.close();
}

@test:Config
function testToolkitRejectsInvalidConfig() {
    resetMock();
    LongTermMemoryToolKit|Error noNamespaces = new (mockConnectionConfig(), MOCK_MEMORY_ID, namespaces = []);
    test:assertTrue(noNamespaces is Error);
    test:assertTrue((<Error>noNamespaces).message().includes("at least one namespace"));

    foreach int topK in [0, -5, MAX_PAGE_SIZE + 1] {
        LongTermMemoryToolKit|Error toolkit =
            new (mockConnectionConfig(), MOCK_MEMORY_ID, namespaces = ["/facts/user-42"], topK = topK);
        test:assertTrue(toolkit is Error, string `topK=${topK} should be rejected`);
        test:assertTrue((<Error>toolkit).message().includes("Invalid topK"));
    }
}

@test:Config
function testSearchMemoryResolvesTemplatesAndMapsResults() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [
            {
                "content": {"text": "prefers dark mode"},
                "createdAt": 1758000000,
                "memoryRecordId": "rec-1",
                "memoryStrategyId": "strategy-1",
                "namespaces": ["/facts/user-42"],
                "score": 0.42
            }
        ]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/{actorId}"], namespaceVariables = {"actorId": "user-42"});

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "theme"});
    test:assertEquals(matches.length(), 1);
    test:assertEquals(matches[0].text, "prefers dark mode");
    test:assertEquals(matches[0].score, 0.42);
    test:assertEquals(matches[0].namespaces, ["/facts/user-42"]);
    test:assertEquals(matches[0].label, "user-42", "the label comes from the most specific namespace segment");
    test:assertEquals(matches[0].createdAt, "2025-09-16T05:20:00Z");
    check toolkit.close();
}

@test:Config
function testSearchMemoryIssuesOnePagePerNamespaceAndMergesByScore() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [summaryJson("rec-a", "low", 0.10), summaryJson("rec-b", "high", 0.90)],
        "/prefs/user-42": [summaryJson("rec-c", "middle", 0.50)]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/{actorId}", "/prefs/{actorId}"], namespaceVariables = {"actorId": "user-42"});

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "anything"});
    test:assertEquals(from MemoryRecordMatch m in matches select m.text, ["high", "middle", "low"]);
    test:assertEquals(mockCallCount("RetrieveMemoryRecords"), 2, "exactly one page per configured namespace");
    check toolkit.close();
}

@test:Config
function testSearchMemoryTruncatesToTopK() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [summaryJson("r1", "one", 0.9), summaryJson("r2", "two", 0.8)],
        "/prefs/user-42": [summaryJson("r3", "three", 0.7), summaryJson("r4", "four", 0.6)]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/{actorId}", "/prefs/{actorId}"],
            namespaceVariables = {"actorId": "user-42"}, topK = 2);

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "anything"});
    test:assertEquals(from MemoryRecordMatch m in matches select m.text, ["one", "two"]);
    check toolkit.close();
}

@test:Config
function testUnscoredRecordsSortLastButAreStillReturned() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [
            {
                "content": {"text": "unscored"},
                "createdAt": 1758000000,
                "memoryRecordId": "rec-u",
                "memoryStrategyId": "strategy-1",
                "namespaces": ["/facts/user-42"]
            },
            summaryJson("rec-s", "scored", 0.5)
        ]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/user-42"]);

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "anything"});
    test:assertEquals(from MemoryRecordMatch m in matches select m.text, ["scored", "unscored"]);
    test:assertTrue(matches[1].score is ());
    check toolkit.close();
}

@test:Config
function testRecordWithoutNamespacesFallsBackToItsId() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [
            {
                "content": {"text": "orphan"},
                "createdAt": 1758000000,
                "memoryRecordId": "rec-orphan",
                "memoryStrategyId": "strategy-1"
            }
        ]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/user-42"]);

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "anything"});
    test:assertEquals(matches[0].label, "rec-orphan");
    test:assertEquals(matches[0].namespaces, []);
    check toolkit.close();
}

@test:Config
function testRecordWithNonTextContentDegradesToEmptyText() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [
            {
                "content": {"binary": "unreadable"},
                "createdAt": 1758000000,
                "memoryRecordId": "rec-bin",
                "memoryStrategyId": "strategy-1",
                "namespaces": ["/facts/user-42"]
            }
        ]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/user-42"]);

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "anything"});
    test:assertEquals(matches[0].text, "");
    check toolkit.close();
}

@test:Config
function testUnresolvableNamespaceTemplateFailsTheSearch() returns error? {
    resetMock();
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/{actorId}"]);

    MemoryRecordMatch[]|Error matches = toolkit.searchMemory({query: "anything"});
    test:assertTrue(matches is Error);
    test:assertEquals(mockCallCount("RetrieveMemoryRecords"), 0, "an unresolved namespace must not be searched");
    check toolkit.close();
}

// The query is the only LLM-controlled value that reaches `retrieveMemoryRecords`; namespaces come
// exclusively from static config. These cases pin that: nothing an attacker can put in a tool call
// changes which namespace is searched.
@test:Config
function testToolInputCannotRedirectTheSearchToAnotherNamespace() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [summaryJson("rec-mine", "my fact", 0.5)],
        "/facts/victim": [summaryJson("rec-theirs", "someone else's secret", 0.99)],
        "": [summaryJson("rec-root", "everything", 0.99)],
        "/facts/*": [summaryJson("rec-wild", "all facts", 0.99)]
    });
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/{actorId}"], namespaceVariables = {"actorId": "user-42"});

    string[] hostileQueries = [
        "/facts/victim",
        "../victim",
        "{actorId}",
        "user-42\"}, \"namespace\": \"/facts/victim\", \"x\": {\"",
        "*",
        "\u{0000}/facts/victim"
    ];
    foreach string query in hostileQueries {
        MemoryRecordMatch[] matches = check toolkit.searchMemory({query});
        test:assertEquals(from MemoryRecordMatch m in matches select m.text, ["my fact"],
                string `query '${query}' reached records outside the configured namespace`);
    }

    // Every call went to the one configured namespace, with the hostile value confined to the query.
    foreach string namespace in mockRetrievedNamespaces() {
        test:assertEquals(namespace, "/facts/user-42");
    }
    test:assertEquals(mockRetrievedNamespaces().length(), hostileQueries.length());
    check toolkit.close();
}

@test:Config
function testNamespaceVariablesCannotSmuggleInASecondSubstitution() returns error? {
    resetMock();
    setMockRecords({"/facts/user-42": [summaryJson("rec-mine", "my fact", 0.5)]});
    // A variable value that itself looks like a placeholder is a literal, never re-resolved.
    LongTermMemoryToolKit toolkit = check new (mockConnectionConfig(), MOCK_MEMORY_ID,
            namespaces = ["/facts/{actorId}"], namespaceVariables = {"actorId": "{admin}", "admin": "user-42"});

    MemoryRecordMatch[] matches = check toolkit.searchMemory({query: "anything"});
    test:assertEquals(matches.length(), 0);
    test:assertEquals(mockRetrievedNamespaces(), ["/facts/{admin}"]);
    check toolkit.close();
}

isolated function summaryJson(string id, string text, float score) returns json => {
    "content": {"text": text},
    "createdAt": 1758000000,
    "memoryRecordId": id,
    "memoryStrategyId": "strategy-1",
    "namespaces": ["/facts/user-42"],
    "score": score
};
