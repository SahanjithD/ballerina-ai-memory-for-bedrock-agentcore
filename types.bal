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
import ballerinax/aws;
import ballerinax/aws.auth;

# Deletion behavior for `agentcore:Memory.delete`.
@display {label: "Delete Mode"}
public enum DeleteMode {
    # Writes a reset marker event so `get` treats the session as empty from that point on, without
    # calling AWS `DeleteEvent`. The prior events remain in AgentCore (subject to the memory
    # resource's `eventExpiryDuration`), so this mode never hits the `DeleteEvent` account-level
    # quota and is safe to call frequently.
    @display {label: "Soft"}
    SOFT,
    # Additionally issues `DeleteEvent` for every prior event of the session, physically removing
    # them. Rate-limited client-side to stay under the `DeleteEvent` account quota.
    @display {label: "Physical"}
    PHYSICAL
}

# Derives the AgentCore `actorId`/`sessionId` pair to use for a given `ai:Memory` session key.
#
# AgentCore indexes events by an `(actorId, sessionId)` pair, but `ai:Memory` is only given a
# single session key string. Use `FixedActorSessionKeyConfig` when every session in the
# application belongs to the same actor (a single-tenant agent); use
# `CompositeSessionKeyConfig` when the session key itself already encodes both, e.g.
# `"user-42/chat-7"`.
@display {label: "Session Key Configuration"}
public type SessionKeyConfig FixedActorSessionKeyConfig|CompositeSessionKeyConfig;

# Uses one fixed `actorId` for every session; the `ai:Memory` session key is used as-is for
# AgentCore's `sessionId` (after sanitization, see `[[session_key.bal]]`).
@display {label: "Fixed Actor Session Key"}
public type FixedActorSessionKeyConfig record {|
    # The AgentCore actor identifier to use for every session.
    @display {label: "Actor ID"}
    string actorId;
|};

# Splits the single `ai:Memory` session key into an `actorId` and a `sessionId` on the first
# occurrence of `separator`. The key must contain the separator exactly once, e.g. with the
# default separator, `"user-42/chat-7"` resolves to actorId `"user-42"`, sessionId `"chat-7"`.
@display {label: "Composite Session Key"}
public type CompositeSessionKeyConfig record {|
    # The separator used to split the session key into `[actorId, sessionId]`.
    @display {label: "Separator"}
    string separator = "/";
|};

# Configuration for `agentcore:Memory`.
@display {label: "Memory Configuration"}
public type MemoryConfig record {|
    # The AWS region hosting the AgentCore Memory resource.
    @display {label: "Region"}
    aws:Region|string region;
    # The AWS credential source. Defaults to the standard AWS credential provider chain.
    @display {label: "Authentication"}
    auth:AuthConfig|auth:CredentialProvider auth = auth:DEFAULT_CREDENTIALS;
    # Overrides endpoint resolution, e.g. to point at a local test double via `customEndpoint`.
    @display {label: "Endpoint Configuration"}
    aws:EndpointConfig endpointConfig = {};
    # The underlying HTTP client configuration used for both the data-plane and (when
    # `verifyMemory` is used) control-plane endpoints.
    @display {label: "HTTP Client Configuration"}
    http:ClientConfiguration httpConfig = {};
    # The identifier of the AgentCore Memory resource to read from and write to - the plain id
    # (e.g. `my-memory-ab12cd34ef`), not the full ARN. This module interpolates `memoryId` directly
    # into both the signed request path and the HTTP request path without URL-encoding it, and the
    # control-plane `GetMemory` id pattern used by `verifyMemory` does not accept an ARN either; an
    # ARN's embedded `:`/`/` characters would break both.
    @display {label: "Memory ID"}
    string memoryId;
    # How `ai:Memory` session keys are mapped to AgentCore `actorId`/`sessionId` pairs.
    @display {label: "Session Key Configuration"}
    SessionKeyConfig sessionKeyConfig;
    # How `delete` removes a session's history. Defaults to `SOFT`.
    @display {label: "Delete Mode"}
    DeleteMode deleteMode = SOFT;
    # When `true`, `init` calls the AgentCore control plane (`GetMemory`) to confirm the
    # configured `memoryId` exists and is `ACTIVE` before returning. Requires the
    # `bedrock-agentcore:GetMemory` permission in addition to the data-plane permissions. Defaults
    # to `false` so initialization never needs control-plane access.
    @display {label: "Verify Memory"}
    boolean verifyMemory = false;
    # The `maxResults` requested on the single `ListEvents` call each `get` makes (1-100; AgentCore
    # allows no larger page). Defaults to 100. If a session has more events than this, which ones
    # come back is `ListEvents`' own undocumented choice - this module does not page further to
    # find "the rest", since paging every page of a very long session would be both slow and, per
    # AWS's pricing model, an unbounded per-call cost.
    @display {label: "Max Events Per Get"}
    int maxEventsPerGet = 100;
|};
