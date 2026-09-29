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

type ConnectionConfig record {|
    aws:Region|string region;
    auth:AuthConfig|auth:CredentialProvider auth;
    aws:EndpointConfig endpointConfig;
    http:ClientConfiguration httpConfig;
|};

// The signed HTTP transport `agentcore:Memory` is built on: the AgentCore Memory data-plane API
// (`CreateEvent`/`ListEvents`/`DeleteEvent`) and, for `getMemory`, the control-plane API.
isolated client class MemoryClient {
    private final http:Client dataPlaneHttp;
    private final string dataPlaneHost;
    private final http:Client controlPlaneHttp;
    private final string controlPlaneHost;
    private final auth:CredentialProvider credentialProvider;
    private final aws:Region|string region;

    isolated function init(ConnectionConfig config) returns Error? {
        self.region = config.region;
        self.dataPlaneHost = aws:resolveEndpointHost(DATA_PLANE_SERVICE, config.region, config.endpointConfig);
        self.controlPlaneHost = aws:resolveEndpointHost(CONTROL_PLANE_SERVICE, config.region, config.endpointConfig);

        // `aws:resolveEndpoint` (not `resolveEndpointHost`) is used for the client's base URL so
        // that `endpointConfig.customEndpoint` keeps whatever scheme it was given (e.g. plain
        // `http://` for a local test double) instead of always being forced onto `https://`.
        string dataPlaneUrl = aws:resolveEndpoint(DATA_PLANE_SERVICE, config.region, config.endpointConfig);
        http:Client|error dataPlaneHttp = new (dataPlaneUrl, config.httpConfig);
        if dataPlaneHttp is error {
            return error Error("Failed to initialize the AgentCore data-plane HTTP client: " +
                dataPlaneHttp.message(), dataPlaneHttp);
        }
        self.dataPlaneHttp = dataPlaneHttp;

        string controlPlaneUrl = aws:resolveEndpoint(CONTROL_PLANE_SERVICE, config.region, config.endpointConfig);
        http:Client|error controlPlaneHttp = new (controlPlaneUrl, config.httpConfig);
        if controlPlaneHttp is error {
            return error Error("Failed to initialize the AgentCore control-plane HTTP client: " +
                controlPlaneHttp.message(), controlPlaneHttp);
        }
        self.controlPlaneHttp = controlPlaneHttp;

        auth:AuthConfig|auth:CredentialProvider authConfig = config.auth;
        if authConfig is auth:CredentialProvider {
            self.credentialProvider = authConfig;
        } else {
            auth:CredentialProvider|auth:CredentialResolutionError credentialProvider = new (authConfig);
            if credentialProvider is auth:CredentialResolutionError {
                return error Error("Failed to initialize the AWS credential provider: " +
                    credentialProvider.message(), credentialProvider);
            }
            self.credentialProvider = credentialProvider;
        }
    }

    remote isolated function createEvent(string memoryId, string actorId, string sessionId, time:Utc eventTimestamp,
            json[] payload) returns WireEvent|Error {
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

    // AWS documents no ordering for `ListEvents`; callers sort client-side (see `memory_read.bal`).
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

    remote isolated function getMemory(string memoryId) returns ControlPlaneMemory|Error {
        // The control plane's *endpoint* prefix is "bedrock-agentcore-control", but its SigV4
        // *signing* name is "bedrock-agentcore" - the same as the data plane (verified against
        // the service's own model: `endpointPrefix` and `signingName` differ only here). Signing
        // with `CONTROL_PLANE_SERVICE` would produce a credential scope AWS never issued
        // credentials against, failing every `verifyMemory` call with `InvalidSignatureException`.
        json response = check self.sendSigned(self.controlPlaneHttp, self.controlPlaneHost, DATA_PLANE_SERVICE,
            "GET", getMemoryPath(memoryId), ());
        GetMemoryResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the GetMemory response: " + decoded.message(), decoded);
        }
        return decoded.memory;
    }

    remote isolated function listMemories(string? nextToken = ()) returns ListMemoriesResponse|Error {
        ListMemoriesRequest request = {maxResults: MAX_PAGE_SIZE, nextToken};
        json response = check self.sendSigned(self.controlPlaneHttp, self.controlPlaneHost, DATA_PLANE_SERVICE,
            "POST", listMemoriesPath(), request.toJson());
        ListMemoriesResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the ListMemories response: " + decoded.message(), decoded);
        }
        return decoded;
    }

    // The `clientToken` is minted once per call and so is identical across this call's retries,
    // which makes a retried `CreateMemory` idempotent rather than a second creation attempt.
    remote isolated function createMemory(string name, int eventExpiryDuration, string? description = (),
            string? encryptionKeyArn = (), map<string>? tags = ()) returns ControlPlaneMemory|Error {
        CreateMemoryRequest request = {clientToken: uuid:createRandomUuid(), name, eventExpiryDuration};
        if description is string {
            request.description = description;
        }
        if encryptionKeyArn is string {
            request.encryptionKeyArn = encryptionKeyArn;
        }
        if tags is map<string> {
            request.tags = tags;
        }
        json response = check self.sendSigned(self.controlPlaneHttp, self.controlPlaneHost, DATA_PLANE_SERVICE,
            "POST", createMemoryPath(), request.toJson());
        CreateMemoryResponse|error decoded = response.fromJsonWithType();
        if decoded is error {
            return error Error("Failed to decode the CreateMemory response: " + decoded.message(), decoded);
        }
        return decoded.memory;
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
            // Not retried: a misconfigured/absent credential source will not start working
            // between one retry attempt and the next a few seconds later (see `retry.bal`'s
            // `LOCAL_FAILURE_ERROR_CODE`).
            return error Error("Failed to resolve AWS credentials: " + credentials.message(),
                credentials, errorCode = LOCAL_FAILURE_ERROR_CODE);
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
            // Not retried, for the same reason as the credential-resolution failure above.
            return error Error("Failed to sign the AgentCore request: " + signedHeaders.message(),
                signedHeaders, errorCode = LOCAL_FAILURE_ERROR_CODE);
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
            // Unlike the credential/signing failures above, a transport failure (connect
            // timeout, connection reset, DNS blip) is exactly the kind of thing a retry can
            // paper over, so this one keeps the default "no error code -> retryable" behavior.
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
            // AWS `rest-json` services are inconsistent about the casing of this field across
            // operations/services; check both rather than silently falling back to the generic
            // message above and losing the "which parameter is invalid" detail AWS sent.
            json? messageField = errorPayload["message"] ?: errorPayload["Message"];
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
