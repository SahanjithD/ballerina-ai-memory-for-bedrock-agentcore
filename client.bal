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
import ballerina/lang.runtime;
import ballerina/time;
import ballerina/uuid;
import ballerinax/aws;
import ballerinax/aws.auth;

# A low-level typed client for the Bedrock AgentCore Memory data-plane API
# (`CreateEvent`/`ListEvents`/`DeleteEvent`/`RetrieveMemoryRecords`), and, for `getMemory`, the
# control-plane API. `agentcore:Memory` and `agentcore:LongTermMemoryToolKit` are both built on
# top of this; use it directly for lower-level access (e.g. branches, or memory records outside
# what the toolkit exposes).
public isolated client class MemoryClient {
    private final http:Client dataPlaneHttp;
    private final string dataPlaneHost;
    private final http:Client controlPlaneHttp;
    private final string controlPlaneHost;
    private final auth:CredentialProvider credentialProvider;
    private final boolean ownsCredentialProvider;
    private final aws:Region|string region;

    # Initializes the client.
    #
    # + config - The connection configuration
    # + return - An `Error` if the underlying HTTP clients or credential provider fail to
    # initialize
    public isolated function init(*ConnectionConfig config) returns Error? {
        self.region = config.region;
        self.dataPlaneHost = aws:resolveEndpointHost(DATA_PLANE_SERVICE, config.region, config.endpointConfig);
        self.controlPlaneHost = aws:resolveEndpointHost(CONTROL_PLANE_SERVICE, config.region, config.endpointConfig);

        http:Client|error dataPlaneHttp = new (string `https://${self.dataPlaneHost}`, config.httpConfig);
        if dataPlaneHttp is error {
            return error Error("Failed to initialize the AgentCore data-plane HTTP client: " +
                dataPlaneHttp.message(), dataPlaneHttp);
        }
        self.dataPlaneHttp = dataPlaneHttp;

        http:Client|error controlPlaneHttp = new (string `https://${self.controlPlaneHost}`, config.httpConfig);
        if controlPlaneHttp is error {
            return error Error("Failed to initialize the AgentCore control-plane HTTP client: " +
                controlPlaneHttp.message(), controlPlaneHttp);
        }
        self.controlPlaneHttp = controlPlaneHttp;

        auth:AuthConfig|auth:CredentialProvider authConfig = config.auth;
        if authConfig is auth:CredentialProvider {
            self.credentialProvider = authConfig;
            self.ownsCredentialProvider = false;
        } else {
            auth:CredentialProvider|auth:CredentialResolutionError credentialProvider = new (authConfig);
            if credentialProvider is auth:CredentialResolutionError {
                return error Error("Failed to initialize the AWS credential provider: " +
                    credentialProvider.message(), credentialProvider);
            }
            self.credentialProvider = credentialProvider;
            self.ownsCredentialProvider = true;
        }
    }

    # Creates one event, carrying the given payload items, for a session.
    #
    # + memoryId - The AgentCore Memory resource id
    # + actorId - The sanitized actor id
    # + sessionId - The sanitized session id
    # + eventTimestamp - The timestamp to record for the event
    # + payload - The event's payload items (see `envelope.bal`)
    # + return - The created event, or an `Error`
    remote isolated function createEvent(string memoryId, string actorId, string sessionId,
            time:Utc eventTimestamp, json[] payload) returns WireEvent|Error {
        CreateEventRequest request = {
            actorId,
            sessionId,
            eventTimestamp: toWireTimestamp(eventTimestamp),
            payload,
            clientToken: uuid:createRandomUuid()
        };
        json response = check self.sendSigned(self.dataPlaneHttp, self.dataPlaneHost, DATA_PLANE_SERVICE, "POST",
            createEventPath(memoryId), request.toJson());
        CreateEventResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the CreateEvent response: " + decoded.message(), decoded);
        }
        return decoded.event;
    }

    # Lists events for a session, newest-first per AgentCore's own ordering where documented, but
    # callers must not rely on server-side order - AWS documents none for `ListEvents` (see
    # `memory_read.bal`, which sorts client-side).
    #
    # + memoryId - The AgentCore Memory resource id
    # + actorId - The sanitized actor id
    # + sessionId - The sanitized session id
    # + maxResults - The page size, 1-100
    # + nextToken - The pagination token from a previous page, if any
    # + return - The page of events plus an optional `nextToken`, or an `Error`
    remote isolated function listEvents(string memoryId, string actorId, string sessionId, int maxResults,
            string? nextToken = ()) returns ListEventsResponse|Error {
        ListEventsRequest request = {maxResults, nextToken};
        json response = check self.sendSigned(self.dataPlaneHttp, self.dataPlaneHost, DATA_PLANE_SERVICE, "POST",
            listEventsPath(memoryId, actorId, sessionId), request.toJson());
        ListEventsResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the ListEvents response: " + decoded.message(), decoded);
        }
        return decoded;
    }

    # Physically deletes one event.
    #
    # + memoryId - The AgentCore Memory resource id
    # + actorId - The sanitized actor id
    # + sessionId - The sanitized session id
    # + eventId - The event id to delete, in AWS's `<number>#<hex>` format
    # + return - The deleted event's id, or an `Error`
    remote isolated function deleteEvent(string memoryId, string actorId, string sessionId, string eventId)
            returns string|Error {
        string signerPath = deleteEventSignerPath(memoryId, actorId, sessionId, eventId);
        string httpPath = deleteEventHttpPath(memoryId, actorId, sessionId, eventId);
        json response = check self.sendSignedWithPaths(self.dataPlaneHttp, self.dataPlaneHost, DATA_PLANE_SERVICE,
            "DELETE", signerPath, httpPath, ());
        DeleteEventResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the DeleteEvent response: " + decoded.message(), decoded);
        }
        return decoded.eventId;
    }

    # Searches long-term memory records.
    #
    # + memoryId - The AgentCore Memory resource id
    # + namespace - The namespace prefix to search
    # + searchQuery - The natural-language search query
    # + topK - The maximum number of results to return
    # + nextToken - The pagination token from a previous page, if any
    # + return - The matching memory record summaries plus an optional `nextToken`, or an `Error`
    remote isolated function retrieveMemoryRecords(string memoryId, string namespace, string searchQuery, int topK,
            string? nextToken = ()) returns RetrieveMemoryRecordsResponse|Error {
        RetrieveMemoryRecordsRequest request = {
            namespace,
            nextToken,
            searchCriteria: {searchQuery, topK}
        };
        json response = check self.sendSigned(self.dataPlaneHttp, self.dataPlaneHost, DATA_PLANE_SERVICE, "POST",
            retrieveMemoryRecordsPath(memoryId), request.toJson());
        RetrieveMemoryRecordsResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the RetrieveMemoryRecords response: " + decoded.message(), decoded);
        }
        return decoded;
    }

    # Fetches a memory resource's control-plane details (used by `verifyMemory`).
    #
    # + memoryId - The AgentCore Memory resource id
    # + return - The memory resource's `id` and `status`, or an `Error`
    remote isolated function getMemory(string memoryId) returns ControlPlaneMemory|Error {
        json response = check self.sendSigned(self.controlPlaneHttp, self.controlPlaneHost, CONTROL_PLANE_SERVICE,
            "GET", getMemoryPath(memoryId), ());
        GetMemoryResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the GetMemory response: " + decoded.message(), decoded);
        }
        return decoded.memory;
    }

    # Releases the resources held by this client (and, if this client created its own credential
    # provider, that provider's resources too).
    #
    # + return - An `Error` if releasing resources fails, or `()`
    public isolated function close() returns Error? {
        if self.ownsCredentialProvider {
            auth:Error? result = self.credentialProvider.close();
            if result is auth:Error {
                return error Error("Failed to close the AWS credential provider: " + result.message(), result);
            }
        }
    }

    private isolated function sendSigned(http:Client target, string host, string serviceName, string method,
            string path, json? body) returns json|Error =>
        self.sendSignedWithPaths(target, host, serviceName, method, path, path, body);

    // `signerPath` is what is handed to the SigV4 signer (unencoded); `httpPath` is what is
    // actually sent as the HTTP request path. They differ only for `DeleteEvent` (see
    // `endpoint.bal`); every other caller passes the same value for both via `sendSigned`.
    private isolated function sendSignedWithPaths(http:Client target, string host, string serviceName, string method,
            string signerPath, string httpPath, json? body) returns json|Error {
        byte[] payload;
        if body is () {
            payload = [];
        } else {
            payload = body.toJsonString().toBytes();
        }
        foreach int attempt in 0 ... MAX_RETRY_ATTEMPTS {
            if attempt > 0 {
                runtime:sleep(backoffDelay(attempt - 1));
            }
            json|Error result = self.sendOnce(target, host, serviceName, method, signerPath, httpPath, payload);
            if result is json {
                return result;
            }
            if attempt == MAX_RETRY_ATTEMPTS || !isRetryableError(result.detail().httpStatusCode, result.detail().errorCode) {
                return result;
            }
        }
        // Unreachable: the loop above always returns on its final iteration (attempt reaches
        // MAX_RETRY_ATTEMPTS, whose branch above always returns).
        panic error("unreachable: retry loop exited without returning a result");
    }

    private isolated function sendOnce(http:Client target, string host, string serviceName, string method,
            string signerPath, string httpPath, byte[] payload) returns json|Error {
        auth:Credentials|auth:CredentialResolutionError credentials = self.credentialProvider.getCredentials();
        if credentials is auth:CredentialResolutionError {
            return error Error("Failed to resolve AWS credentials: " + credentials.message(), credentials);
        }

        map<string> headers = payload.length() > 0 ? {"content-type": "application/json"} : {};
        auth:SignatureRequest signatureRequest = {
            method,
            host,
            path: signerPath,
            headers,
            payload
        };
        map<string>|auth:SigningError signedHeaders =
            auth:getSignedHeaders(signatureRequest, credentials, self.region, serviceName);
        if signedHeaders is auth:SigningError {
            return error Error("Failed to sign the AgentCore request: " + signedHeaders.message(), signedHeaders);
        }

        http:Request request = new;
        if payload.length() > 0 {
            request.setBinaryPayload(payload);
        }
        foreach [string, string] [name, value] in signedHeaders.entries() {
            request.setHeader(name, value);
        }
        if payload.length() > 0 {
            request.setHeader("content-type", "application/json");
        }

        http:Response|http:ClientError response = target->execute(method, httpPath, request);
        if response is http:ClientError {
            return error Error("Failed to call AgentCore: " + response.message(), response);
        }
        return self.toResult(response);
    }

    private isolated function toResult(http:Response response) returns json|Error {
        int statusCode = response.statusCode;

        if statusCode >= 200 && statusCode < 300 {
            json|http:ClientError payload = response.getJsonPayload();
            if payload is http:ClientError {
                return error Error("AgentCore returned a non-JSON success response: " + payload.message(), payload);
            }
            return payload;
        }

        string? requestId = optionalHeader(response, "x-amzn-requestid");
        string errorMessage = string `AgentCore call failed with HTTP status ${statusCode}`;
        json|http:ClientError errorPayload = response.getJsonPayload();
        if errorPayload is map<json> {
            json? messageField = errorPayload["message"];
            if messageField is string {
                errorMessage = messageField;
            }
        }

        string? errorCode = ();
        string? rawErrorType = optionalHeader(response, "x-amzn-errortype");
        if rawErrorType is string {
            // AWS sends this header as e.g. "ValidationException:https://..."; keep only the type.
            int? colonIndex = rawErrorType.indexOf(":");
            errorCode = colonIndex is int ? rawErrorType.substring(0, colonIndex) : rawErrorType;
        }

        return buildError(errorMessage, statusCode, response.reasonPhrase, errorCode, requestId);
    }
}

isolated function optionalHeader(http:Response response, string name) returns string? {
    string|http:HeaderNotFoundError value = response.getHeader(name);
    return value is string ? value : ();
}

// Error constructors do not support spreading a partially-populated detail record (`...detail`
// rest args are not allowed there), so this covers the four combinations of the two genuinely
// optional detail fields explicitly.
isolated function buildError(string message, int httpStatusCode, string httpStatusText, string? errorCode,
        string? requestId) returns Error {
    if errorCode is string && requestId is string {
        return error Error(message, httpStatusCode = httpStatusCode, httpStatusText = httpStatusText,
            errorCode = errorCode, errorMessage = message, requestId = requestId);
    }
    if errorCode is string {
        return error Error(message, httpStatusCode = httpStatusCode, httpStatusText = httpStatusText,
            errorCode = errorCode, errorMessage = message);
    }
    if requestId is string {
        return error Error(message, httpStatusCode = httpStatusCode, httpStatusText = httpStatusText,
            errorMessage = message, requestId = requestId);
    }
    return error Error(message, httpStatusCode = httpStatusCode, httpStatusText = httpStatusText, errorMessage = message);
}
