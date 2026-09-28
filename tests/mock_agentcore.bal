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

import ballerina/http;
import ballerinax/aws.auth;

// A stand-in for the AgentCore Memory data plane (and, on the same port, the one control-plane
// operation this module calls). Tests reach it through `ConnectionConfig.endpointConfig
// .customEndpoint`, so every contract test runs through the real `MemoryClient`: real SigV4
// signing, real retry loop, real URI building - nothing is stubbed out below the client.
//
// The port is `configurable` purely so a busy CI box can move it; `bal test` needs no
// `tests/Config.toml` to run.
configurable int mockPort = 9977;

const string MOCK_REGION = "us-east-1";
const string MOCK_MEMORY_ID = "mock-memory-ab12cd34";

// Obviously-fake placeholder credentials: the signer only HMACs them, it never validates them, and
// the mock only checks that the resulting `Authorization` header is well-formed.
final auth:StaticAuthConfig & readonly MOCK_CREDENTIALS = {
    accessKeyId: "mock-access-key-id",
    secretAccessKey: "mock-secret-access-key"
};

isolated function mockConnectionConfig() returns ConnectionConfig => {
    region: MOCK_REGION,
    auth: MOCK_CREDENTIALS,
    endpointConfig: {customEndpoint: string `http://localhost:${mockPort}`}
};

isolated function mockMemoryConfig(SessionKeyConfig sessionKeyConfig, DeleteMode deleteMode = SOFT,
        int maxEventsPerGet = MAX_PAGE_SIZE) returns MemoryConfig => {
    region: MOCK_REGION,
    auth: MOCK_CREDENTIALS,
    endpointConfig: {customEndpoint: string `http://localhost:${mockPort}`},
    memoryId: MOCK_MEMORY_ID,
    sessionKeyConfig,
    deleteMode,
    maxEventsPerGet
};

type MockEvent record {|
    string eventId;
    string actorId;
    string sessionId;
    decimal eventTimestamp;
    json[] payload;
|};

// One record rather than a field per concern: a `lock` statement may touch only one
// access-restricted variable, and several of the helpers below need more than one field at a time.
type MockState record {|
    // AWS assigns event ids as `<number>#<hex>` with a strictly increasing numeric prefix, and that
    // `#` is what the `DeleteEvent` path has to encode - so the mock mints ids in the real format
    // rather than handing out UUIDs the encoding bug would never show up against.
    int sequence = 1758000000000;
    map<MockEvent[]> events = {};
    boolean listOrderReversed = false;
    map<int> callCounts = {};
    map<string> authHeaders = {};
    string[] deleteRawPaths = [];
    map<json> recordsByNamespace = {};
    json[] listEventsBodies = [];
    string[] retrieveNamespaces = [];
    json[] retrieveBodies = [];
    string memoryStatus = "ACTIVE";
    int failuresRemaining = 0;
    int failureStatus = 429;
    string failureErrorType = "ThrottledException";
    // "" fails whichever operation comes next; a name confines the injected failure to that one.
    string failureOperation = "";
|};

isolated MockState mockState = {};

service / on new http:Listener(mockPort) {

    resource function post memories/[string memoryId]/events(http:Request request) returns json|http:Response|error {
        recordCall("CreateEvent", request);
        http:Response? failure = injectedFailure("CreateEvent");
        if failure is http:Response {
            return failure;
        }
        map<json> body = <map<json>>check request.getJsonPayload();
        json[] payload = <json[]>body["payload"];
        if payload.length() > MAX_PAYLOAD_ITEMS {
            return validationFailure(string `payload must have at most ${MAX_PAYLOAD_ITEMS} items`);
        }
        json? invalidText = firstInvalidConversationalText(payload);
        if invalidText is string {
            return validationFailure(invalidText);
        }
        MockEvent event = {
            eventId: nextMockEventId(),
            actorId: <string>body["actorId"],
            sessionId: <string>body["sessionId"],
            eventTimestamp: <decimal>check (<json>body["eventTimestamp"]).cloneWithType(),
            payload
        };
        storeMockEvent(memoryId, event);
        return {"event": wireEventJson(memoryId, event)};
    }

    resource function post memories/[string memoryId]/actor/[string actorId]/sessions/[string sessionId](
            http:Request request) returns json|http:Response|error {
        recordCall("ListEvents", request);
        http:Response? failure = injectedFailure("ListEvents");
        if failure is http:Response {
            return failure;
        }
        map<json> body = <map<json>>check request.getJsonPayload();
        recordListEvents(body);
        int maxResults = body["maxResults"] is int ? <int>body["maxResults"] : 20;
        int total = storedMockEvents(actorId, sessionId, memoryId).length();
        MockEvent[] events = listMockEvents(memoryId, actorId, sessionId, maxResults);
        json response = {"events": from MockEvent event in events select wireEventJson(memoryId, event)};
        // Offer a continuation token whenever the page was truncated, so a caller that pages when it
        // should not shows up as an extra ListEvents call.
        return total > events.length() ? check (<map<json>>response).mergeJson({"nextToken": "mock-next"}) : response;
    }

    resource function delete memories/[string memoryId]/actor/[string actorId]/sessions/[string sessionId]/events/
            [string eventId](http:Request request) returns json|http:Response {
        recordCall("DeleteEvent", request);
        recordDeleteRawPath(request.rawPath);
        http:Response? failure = injectedFailure("DeleteEvent");
        if failure is http:Response {
            return failure;
        }
        if !deleteMockEvent(memoryId, actorId, sessionId, eventId) {
            return notFoundFailure(string `no such event '${eventId}'`);
        }
        return {"eventId": eventId};
    }

    resource function post memories/[string memoryId]/retrieve(http:Request request)
            returns json|http:Response|error {
        recordCall("RetrieveMemoryRecords", request);
        http:Response? failure = injectedFailure("RetrieveMemoryRecords");
        if failure is http:Response {
            return failure;
        }
        map<json> body = <map<json>>check request.getJsonPayload();
        json? searchCriteria = body["searchCriteria"];
        if searchCriteria !is map<json> || searchCriteria["searchQuery"] !is string {
            return validationFailure("searchCriteria.searchQuery is required");
        }
        string namespace = body["namespace"] is string ? <string>body["namespace"] : "";
        recordRetrieve(namespace, body);
        return {"memoryRecordSummaries": recordsFor(namespace)};
    }

    resource function get memories/[string memoryId]/details(http:Request request) returns json|http:Response {
        recordCall("GetMemory", request);
        http:Response? failure = injectedFailure("GetMemory");
        if failure is http:Response {
            return failure;
        }
        return {"memory": {"id": memoryId, "status": mockStatus(), "eventExpiryDuration": 7}};
    }
}

isolated function wireEventJson(string memoryId, MockEvent event) returns json => {
    "actorId": event.actorId,
    "eventId": event.eventId,
    "eventTimestamp": event.eventTimestamp,
    "memoryId": memoryId,
    "payload": event.payload,
    "sessionId": event.sessionId
};

// AWS rejects a `conversational` item whose text is empty or over 100,000 characters, and rejects
// the whole event with it - including the blob that carries the turn losslessly. The mock enforces
// that so the clamping in `envelope.bal` is checked against a server that behaves like AWS, not
// only by reading the payload.
isolated function firstInvalidConversationalText(json[] payload) returns string? {
    foreach json item in payload {
        if item !is map<json> {
            continue;
        }
        json? conversational = item["conversational"];
        if conversational !is map<json> {
            continue;
        }
        json? content = conversational["content"];
        if content !is map<json> || content["text"] !is string {
            return "conversational.content.text is required";
        }
        string text = <string>content["text"];
        if text.length() == 0 || text.length() > MAX_CONVERSATIONAL_TEXT_LENGTH {
            return string `conversational.content.text must be 1-${MAX_CONVERSATIONAL_TEXT_LENGTH} characters, ` +
                string `got ${text.length()}`;
        }
    }
    return ();
}

isolated function recordCall(string operation, http:Request request) {
    string|http:HeaderNotFoundError authorization = request.getHeader("Authorization");
    string header = authorization is string ? authorization : "";
    lock {
        mockState.callCounts[operation] = (mockState.callCounts[operation] ?: 0) + 1;
        mockState.authHeaders[operation] = header;
    }
}

isolated function recordDeleteRawPath(string rawPath) {
    lock {
        mockState.deleteRawPaths.push(rawPath);
    }
}

isolated function recordListEvents(map<json> body) {
    lock {
        mockState.listEventsBodies.push(body.clone());
    }
}

isolated function recordRetrieve(string namespace, map<json> body) {
    lock {
        mockState.retrieveNamespaces.push(namespace);
        mockState.retrieveBodies.push(body.clone());
    }
}

isolated function recordsFor(string namespace) returns json {
    lock {
        return (mockState.recordsByNamespace[namespace] ?: <json[]>[]).clone();
    }
}

isolated function mockStatus() returns string {
    lock {
        return mockState.memoryStatus;
    }
}

isolated function nextMockEventId() returns string {
    lock {
        mockState.sequence += 1;
        return string `${mockState.sequence}#${(mockState.sequence % 65536).toHexString()}`;
    }
}

isolated function sessionStoreKey(string memoryId, string actorId, string sessionId) returns string =>
    string `${memoryId}|${actorId}|${sessionId}`;

isolated function storeMockEvent(string memoryId, MockEvent event) {
    string key = sessionStoreKey(memoryId, event.actorId, event.sessionId);
    lock {
        MockEvent[] events = mockState.events[key] ?: [];
        events.push(event.clone());
        mockState.events[key] = events;
    }
}

isolated function listMockEvents(string memoryId, string actorId, string sessionId, int maxResults)
        returns MockEvent[] {
    string key = sessionStoreKey(memoryId, actorId, sessionId);
    MockEvent[] events;
    boolean reversed;
    lock {
        events = (mockState.events[key] ?: []).clone();
        reversed = mockState.listOrderReversed;
    }
    if events.length() > maxResults {
        events = events.slice(0, maxResults);
    }
    return reversed ? events.reverse() : events;
}

isolated function deleteMockEvent(string memoryId, string actorId, string sessionId, string eventId)
        returns boolean {
    // Ballerina decodes path parameters, so a `%23` on the wire arrives here as `#`; tolerate both
    // so a routing failure shows up as a failed assertion on the raw path, not as a 404.
    string wanted = re `%23`.replaceAll(eventId, "#");
    string key = sessionStoreKey(memoryId, actorId, sessionId);
    lock {
        MockEvent[] events = mockState.events[key] ?: [];
        MockEvent[] remaining = from MockEvent event in events where event.eventId != wanted select event;
        if remaining.length() == events.length() {
            return false;
        }
        mockState.events[key] = remaining;
        return true;
    }
}

isolated function injectedFailure(string operation) returns http:Response? {
    int status;
    string errorType;
    lock {
        if mockState.failuresRemaining <= 0 ||
            (mockState.failureOperation != "" && mockState.failureOperation != operation) {
            return ();
        }
        mockState.failuresRemaining -= 1;
        status = mockState.failureStatus;
        errorType = mockState.failureErrorType;
    }
    return awsFailure(status, errorType, string `injected ${errorType}`);
}

isolated function validationFailure(string message) returns http:Response =>
    awsFailure(400, "ValidationException", message);

isolated function notFoundFailure(string message) returns http:Response =>
    awsFailure(404, "ResourceNotFoundException", message);

isolated function awsFailure(int status, string errorType, string message) returns http:Response {
    http:Response response = new;
    response.statusCode = status;
    response.setHeader("x-amzn-errortype", string `${errorType}:https://internal.amazon.com/coral/`);
    response.setHeader("x-amzn-requestid", "mock-request-id-0001");
    response.setJsonPayload({"message": message});
    return response;
}

// Test-facing controls and assertions.

isolated function resetMock() {
    lock {
        mockState.events = {};
        mockState.listOrderReversed = false;
        mockState.callCounts = {};
        mockState.authHeaders = {};
        mockState.deleteRawPaths = [];
        mockState.recordsByNamespace = {};
        mockState.listEventsBodies = [];
        mockState.retrieveNamespaces = [];
        mockState.retrieveBodies = [];
        mockState.memoryStatus = "ACTIVE";
        mockState.failuresRemaining = 0;
        mockState.failureOperation = "";
    }
}

isolated function setMockListOrderReversed(boolean reversed) {
    lock {
        mockState.listOrderReversed = reversed;
    }
}

isolated function setMockMemoryStatus(string status) {
    lock {
        mockState.memoryStatus = status;
    }
}

isolated function setMockFailures(int count, int status, string errorType, string operation = "") {
    lock {
        mockState.failuresRemaining = count;
        mockState.failureStatus = status;
        mockState.failureErrorType = errorType;
        mockState.failureOperation = operation;
    }
}

isolated function setMockRecords(map<json> recordsByNamespace) {
    lock {
        mockState.recordsByNamespace = recordsByNamespace.clone();
    }
}

isolated function mockCallCount(string operation) returns int {
    lock {
        return mockState.callCounts[operation] ?: 0;
    }
}

isolated function mockAuthHeader(string operation) returns string {
    lock {
        return mockState.authHeaders[operation] ?: "";
    }
}

isolated function mockDeletePaths() returns string[] {
    lock {
        return mockState.deleteRawPaths.clone();
    }
}

isolated function mockListEventsBodies() returns json[] {
    lock {
        return mockState.listEventsBodies.clone();
    }
}

isolated function mockRetrievedNamespaces() returns string[] {
    lock {
        return mockState.retrieveNamespaces.clone();
    }
}

isolated function mockRetrievedBodies() returns json[] {
    lock {
        return mockState.retrieveBodies.clone();
    }
}

isolated function storedMockEvents(string actorId, string sessionId, string memoryId = MOCK_MEMORY_ID)
        returns MockEvent[] {
    string key = sessionStoreKey(memoryId, actorId, sessionId);
    lock {
        return (mockState.events[key] ?: []).clone();
    }
}

// Injects an event the mock did not mint, to stand in for one written by another SDK or a future
// build of this module.
isolated function injectForeignEvent(string actorId, string sessionId, json[] payload,
        decimal eventTimestamp = 1d) {
    storeMockEvent(MOCK_MEMORY_ID, {
        eventId: nextMockEventId(),
        actorId,
        sessionId,
        eventTimestamp,
        payload
    });
}
