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

import ballerina/time;

// The wire types below are transcribed directly from the AWS API reference for the AgentCore
// Memory data-plane API (`CreateEvent`, `ListEvents`, `DeleteEvent`) and
// the control-plane `GetMemory` operation. Field names and nesting must match the wire exactly -
// they are not "cleaned up" to look more Ballerina-idiomatic.
//
// *Response* records are deliberately open (`record { ... }`, not `record {| ... |}`): AWS adds
// response fields to existing operations routinely, and a closed record's `fromJsonWithType`
// fails on any field it does not know about - which would take every `get`/`searchMemory` call
// down at once the day AWS adds one. *Request* records stay closed: this module fully controls
// what it sends, so there is nothing to be lenient about there.

type WireBranch record {
    string name;
    string rootEventId?;
};

type WireEvent record {
    string actorId;
    WireBranch branch?;
    string eventId;
    decimal eventTimestamp;
    string memoryId;
    map<json> metadata?;
    json[] payload;
    string sessionId;
};

type CreateEventRequest record {|
    string actorId;
    string clientToken?;
    decimal eventTimestamp;
    map<json> metadata?;
    json[] payload;
    string sessionId?;
|};

type CreateEventResponse record {
    WireEvent event;
};

type FilterExpression record {|
    json left;
    string operator;
    json right?;
|};

type FilterInput record {|
    FilterExpression[] eventMetadata?;
|};

type ListEventsRequest record {|
    FilterInput filter?;
    boolean includePayloads = true;
    int maxResults?;
    string nextToken?;
|};

type ListEventsResponse record {
    WireEvent[] events = [];
    string nextToken?;
};

type DeleteEventResponse record {|
    string eventId;
|};

// Control plane (`verifyMemory` only). Only the fields this module actually reads are typed; the
// rest of the (much larger) `Memory` object is deliberately left untyped.
type GetMemoryResponse record {
    ControlPlaneMemory memory;
};

type ControlPlaneMemory record {
    string id;
    string status;
};

// AWS `Timestamp` shapes on `rest-json` services (the protocol this API uses) serialize as epoch
// seconds. Centralized here so a wire-format correction only needs to change one place.
isolated function toWireTimestamp(time:Utc utc) returns decimal {
    var [seconds, fraction] = utc;
    return <decimal>seconds + fraction;
}

isolated function fromWireTimestamp(decimal wireTimestamp) returns time:Utc {
    int seconds = <int>wireTimestamp.floor();
    decimal fraction = wireTimestamp - <decimal>seconds;
    return [seconds, fraction];
}
