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

import ballerina/lang.regexp;
import ballerina/test;
import ballerina/time;

final regexp:RegExp & readonly AWS_EVENT_ID_PATTERN = re `^[0-9]+#[a-fA-F0-9]+$`;

@test:Config
function testCreateEventReturnsAnAwsShapedEventId() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    WireEvent event = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-1", time:utcNow(),
            buildEventPayload([{role: "user", content: "hi"}]));

    test:assertTrue(AWS_EVENT_ID_PATTERN.isFullMatch(event.eventId), string `unexpected id '${event.eventId}'`);
    test:assertEquals(event.actorId, "user-42");
    test:assertEquals(event.sessionId, "chat-1");
    test:assertEquals(event.memoryId, MOCK_MEMORY_ID);
    test:assertEquals(event.payload.length(), 2);
    check agentCoreClient.close();
}

@test:Config
function testEventIdSequenceStrictlyIncreases() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    int previous = -1;
    foreach int i in 0 ..< 4 {
        WireEvent event = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-seq", time:utcNow(),
                buildEventPayload([{role: "user", content: string `m${i}`}]));
        int sequence = eventSequenceNumber(event.eventId);
        test:assertTrue(sequence > previous, "event id prefixes must increase with creation order");
        previous = sequence;
    }
    check agentCoreClient.close();
}

@test:Config
function testListEventsReturnsWhatWasCreated() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());
    _ = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-list", time:utcNow(),
            buildEventPayload([{role: "user", content: "one"}]));
    _ = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-list", time:utcNow(),
            buildEventPayload([{role: "user", content: "two"}]));

    ListEventsResponse page = check agentCoreClient->listEvents(MOCK_MEMORY_ID, "user-42", "chat-list", MAX_PAGE_SIZE);
    test:assertEquals(page.events.length(), 2);
    test:assertTrue(page?.nextToken is ());

    // Another session's events are not visible.
    ListEventsResponse other = check agentCoreClient->listEvents(MOCK_MEMORY_ID, "user-42", "chat-other", MAX_PAGE_SIZE);
    test:assertEquals(other.events.length(), 0);
    check agentCoreClient.close();
}

@test:Config
function testListEventsHonoursMaxResults() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());
    foreach int i in 0 ..< 5 {
        _ = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-page", time:utcNow(),
                buildEventPayload([{role: "user", content: string `m${i}`}]));
    }

    ListEventsResponse page = check agentCoreClient->listEvents(MOCK_MEMORY_ID, "user-42", "chat-page", 2);
    test:assertEquals(page.events.length(), 2);
    check agentCoreClient.close();
}

@test:Config
function testDeleteEventSendsThePercentEncodedEventId() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());
    WireEvent event = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-del", time:utcNow(),
            buildEventPayload([{role: "user", content: "bye"}]));
    test:assertTrue(event.eventId.includes("#"), "the mock must mint AWS-shaped ids for this to mean anything");

    string deletedId = check agentCoreClient->deleteEvent(MOCK_MEMORY_ID, "user-42", "chat-del", event.eventId);
    test:assertEquals(deletedId, event.eventId);
    test:assertEquals(storedMockEvents("user-42", "chat-del").length(), 0);

    string[] rawPaths = mockDeletePaths();
    test:assertEquals(rawPaths.length(), 1);
    test:assertTrue(rawPaths[0].includes("%23"), string `event id was not encoded: '${rawPaths[0]}'`);
    test:assertFalse(rawPaths[0].includes("#"), string `a raw '#' truncates the request line: '${rawPaths[0]}'`);
    check agentCoreClient.close();
}

@test:Config
function testRetrieveMemoryRecordsNestsSearchCriteria() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [
            {
                "content": {"text": "prefers dark mode"},
                "createdAt": 1758000000,
                "memoryRecordId": "rec-1",
                "memoryStrategyId": "strategy-1",
                "namespaces": ["/facts/user-42"],
                "score": 0.91
            }
        ]
    });
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    RetrieveMemoryRecordsResponse response =
        check agentCoreClient->retrieveMemoryRecords(MOCK_MEMORY_ID, "/facts/user-42", "theme preference", 5);

    test:assertEquals(response.memoryRecordSummaries.length(), 1);
    MemoryRecordSummary summary = response.memoryRecordSummaries[0];
    test:assertEquals(summary.content["text"], "prefers dark mode");
    test:assertEquals(summary.namespaces, ["/facts/user-42"]);
    test:assertEquals(summary?.score, 0.91);

    map<json> body = <map<json>>mockRetrievedBodies()[0];
    test:assertEquals(body["namespace"], "/facts/user-42");
    map<json> criteria = <map<json>>body["searchCriteria"];
    test:assertEquals(criteria["searchQuery"], "theme preference");
    test:assertEquals(criteria["topK"], 5);
    check agentCoreClient.close();
}

@test:Config
function testRetrieveMemoryRecordsToleratesAnAdditiveResponseField() returns error? {
    resetMock();
    setMockRecords({
        "/facts/user-42": [
            {
                "content": {"text": "likes tea"},
                "createdAt": 1758000000,
                "memoryRecordId": "rec-1",
                "memoryStrategyId": "strategy-1",
                "namespaces": ["/facts/user-42"],
                // A field AWS could add tomorrow: decoding must not fail for every caller at once.
                "somethingAwsAddedLater": {"nested": true}
            }
        ]
    });
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    RetrieveMemoryRecordsResponse response =
        check agentCoreClient->retrieveMemoryRecords(MOCK_MEMORY_ID, "/facts/user-42", "drinks", 5);
    test:assertEquals(response.memoryRecordSummaries.length(), 1);
    test:assertTrue(response.memoryRecordSummaries[0]?.score is ());
    check agentCoreClient.close();
}

@test:Config
function testGetMemoryReadsTheControlPlane() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    ControlPlaneMemory memory = check agentCoreClient->getMemory(MOCK_MEMORY_ID);
    test:assertEquals(memory.id, MOCK_MEMORY_ID);
    test:assertEquals(memory.status, "ACTIVE");
    check agentCoreClient.close();
}

@test:Config
function testControlPlaneIsSignedWithTheDataPlaneServiceName() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());
    _ = check agentCoreClient->getMemory(MOCK_MEMORY_ID);

    // `bedrock-agentcore-control` is only an endpoint hostname prefix; signing with it produces a
    // credential scope AWS never issued credentials against.
    string authorization = mockAuthHeader("GetMemory");
    test:assertTrue(authorization.startsWith("AWS4-HMAC-SHA256 "), string `unexpected header '${authorization}'`);
    test:assertTrue(authorization.includes("Credential="));
    test:assertTrue(authorization.includes(string `/${MOCK_REGION}/${DATA_PLANE_SERVICE}/aws4_request`),
            string `control-plane call was not signed for '${DATA_PLANE_SERVICE}': '${authorization}'`);
    test:assertFalse(authorization.includes(CONTROL_PLANE_SERVICE + "/aws4_request"),
            string `control-plane call was signed with the endpoint prefix: '${authorization}'`);
    check agentCoreClient.close();
}

@test:Config
function testDataPlaneIsSignedForTheSameService() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());
    _ = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-sign", time:utcNow(),
            buildEventPayload([{role: "user", content: "hi"}]));

    string authorization = mockAuthHeader("CreateEvent");
    test:assertTrue(authorization.includes(string `/${MOCK_REGION}/${DATA_PLANE_SERVICE}/aws4_request`));
    test:assertTrue(authorization.includes("SignedHeaders="));
    test:assertTrue(authorization.includes("Signature="));
    check agentCoreClient.close();
}

@test:Config
function testCustomEndpointSchemeIsHonoured() returns error? {
    // Reaching the mock at all proves the plain `http://` scheme survived endpoint resolution: a
    // client forced onto `https://` cannot complete a single call against it.
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());
    _ = check agentCoreClient->getMemory(MOCK_MEMORY_ID);
    test:assertEquals(mockCallCount("GetMemory"), 1);
    check agentCoreClient.close();
}

@test:Config
function testThrottlingIsRetriedUntilItSucceeds() returns error? {
    resetMock();
    setMockFailures(2, 429, "ThrottledException");
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    WireEvent event = check agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-retry", time:utcNow(),
            buildEventPayload([{role: "user", content: "hi"}]));
    test:assertTrue(event.eventId.length() > 0);
    test:assertEquals(mockCallCount("CreateEvent"), 3, "two throttled attempts should be followed by a success");
    check agentCoreClient.close();
}

@test:Config
function testValidationFailuresAreNotRetried() returns error? {
    resetMock();
    setMockFailures(1, 400, "ValidationException");
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    WireEvent|Error event = agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-noretry", time:utcNow(),
            buildEventPayload([{role: "user", content: "hi"}]));
    test:assertTrue(event is Error);
    Error err = <Error>event;
    test:assertEquals(err.detail()?.httpStatusCode, 400);
    test:assertEquals(err.detail()?.errorCode, "ValidationException");
    test:assertEquals(err.detail()?.requestId, "mock-request-id-0001");
    test:assertEquals(err.message(), "injected ValidationException", "the AWS-sent message must be surfaced");
    test:assertEquals(mockCallCount("CreateEvent"), 1, "a validation failure must not be retried");
    check agentCoreClient.close();
}

@test:Config
function testServerFaultsAreRetriedUpToTheAttemptBudget() returns error? {
    resetMock();
    setMockFailures(MAX_RETRY_ATTEMPTS + 1, 500, "ServiceException");
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    WireEvent|Error event = agentCoreClient->createEvent(MOCK_MEMORY_ID, "user-42", "chat-5xx", time:utcNow(),
            buildEventPayload([{role: "user", content: "hi"}]));
    test:assertTrue(event is Error);
    test:assertEquals(mockCallCount("CreateEvent"), MAX_RETRY_ATTEMPTS + 1);
    check agentCoreClient.close();
}

@test:Config
function testDeletingAMissingEventSurfacesTheAwsError() returns error? {
    resetMock();
    MemoryClient agentCoreClient = check new (mockConnectionConfig());

    string|Error deleted = agentCoreClient->deleteEvent(MOCK_MEMORY_ID, "user-42", "chat-gone", "1758000000001#ff");
    test:assertTrue(deleted is Error);
    test:assertEquals((<Error>deleted).detail()?.httpStatusCode, 404);
    test:assertEquals(mockCallCount("DeleteEvent"), 1, "a 404 must not be retried");
    check agentCoreClient.close();
}
