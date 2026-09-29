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

final regexp:RegExp & readonly HASH_CHAR = re `#`;

isolated function createEventPath(string memoryId) returns string => string `/memories/${memoryId}/events`;

isolated function listEventsPath(string memoryId, string actorId, string sessionId) returns string =>
    string `/memories/${memoryId}/actor/${actorId}/sessions/${sessionId}`;

# Builds the `DeleteEvent` path in the form the AWS SigV4 signer expects: raw, with the event id's
# literal `#` left unencoded. `aws.auth:SignatureRequest.path` is documented "unencoded" - the
# signer does its own URI-encoding when building the canonical request - so this must be the
# logical path, not the one actually sent on the wire (see `deleteEventHttpPath`).
#
# + memoryId - The AgentCore Memory resource id
# + actorId - The sanitized actor id (see `session_key.bal`)
# + sessionId - The sanitized session id (see `session_key.bal`)
# + eventId - The event id to delete, in AWS's `<number>#<hex>` format
# + return - The unencoded logical path
isolated function deleteEventSignerPath(string memoryId, string actorId, string sessionId, string eventId)
        returns string => string `/memories/${memoryId}/actor/${actorId}/sessions/${sessionId}/events/${eventId}`;

# Builds the `DeleteEvent` path as it must actually be sent over HTTP: the event id's `#`
# percent-encoded to `%23`. Left unencoded, `#` would be read as a URI fragment delimiter by
# anything that parses the request line as a URI, silently truncating the path and dropping the
# rest of the event id from the request the server receives - which would neither match the route
# nor the signature computed over `deleteEventSignerPath`'s raw form.
#
# + memoryId - The AgentCore Memory resource id
# + actorId - The sanitized actor id (see `session_key.bal`)
# + sessionId - The sanitized session id (see `session_key.bal`)
# + eventId - The event id to delete, in AWS's `<number>#<hex>` format
# + return - The percent-encoded path to send on the wire
isolated function deleteEventHttpPath(string memoryId, string actorId, string sessionId, string eventId)
        returns string {
    string encodedEventId = HASH_CHAR.replaceAll(eventId, "%23");
    return string `/memories/${memoryId}/actor/${actorId}/sessions/${sessionId}/events/${encodedEventId}`;
}

isolated function getMemoryPath(string memoryId) returns string => string `/memories/${memoryId}/details`;
