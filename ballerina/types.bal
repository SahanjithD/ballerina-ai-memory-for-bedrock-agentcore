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
    # The underlying HTTP client configuration used for both the data-plane and control-plane
    # endpoints.
    @display {label: "HTTP Client Configuration"}
    http:ClientConfiguration httpConfig = {};
    # The identifier of an existing AgentCore Memory resource to use - the plain id (e.g.
    # `my_memory-ab12cd34ef`), not the full ARN. This module interpolates `memoryId` directly into
    # both the signed request path and the HTTP request path without URL-encoding it, and the
    # control-plane `GetMemory` id pattern does not accept an ARN either; an ARN's embedded `:`/`/`
    # characters would break both. When set, `memoryResourceConfig` is ignored and `init` makes no
    # control-plane calls unless `verifyMemory` is `true`. When omitted, the memory resource is
    # looked up by `memoryResourceConfig.memoryName`, and created if it does not exist yet.
    @display {label: "Memory ID"}
    string memoryId?;
    # How the memory resource is found or created when `memoryId` is not set.
    @display {label: "Memory Resource Configuration"}
    MemoryResourceConfig memoryResourceConfig = {};
    # How `ai:Memory` session keys are mapped to AgentCore `actorId`/`sessionId` pairs.
    @display {label: "Session Key Configuration"}
    SessionKeyConfig sessionKeyConfig;
    # How `delete` removes a session's history. Defaults to `SOFT`.
    @display {label: "Delete Mode"}
    DeleteMode deleteMode = SOFT;
    # When `true` and `memoryId` is set, `init` calls the AgentCore control plane (`GetMemory`) to
    # confirm that memory exists and is `ACTIVE` before returning. Requires the
    # `bedrock-agentcore:GetMemory` permission in addition to the data-plane permissions. Defaults
    # to `false`, so a `memoryId`-configured memory never needs control-plane access. Has no effect
    # without `memoryId`: a memory found or created by name is always waited on until `ACTIVE`.
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

# Configuration for the AgentCore Memory resource that backs `agentcore:Memory` when no `memoryId`
# is given.
#
# + memoryName - The memory resource's name, unique within the AWS account and region. Must start
# with a letter and contain only letters, digits, and underscores (at most 48 characters)
# + createMemoryIfNotExists - Whether `init` should create the memory resource when none with
# `memoryName` exists. Defaults to `true`. Finding the resource calls `ListMemories` and
# `GetMemory`, and creating it calls `CreateMemory`, so these need the
# `bedrock-agentcore:ListMemories`, `bedrock-agentcore:GetMemory` and
# `bedrock-agentcore:CreateMemory` IAM permissions. Set to `false` to only ever use an existing
# resource by name, or set `MemoryConfig.memoryId` instead to make no control-plane calls at all
# + eventExpiryDuration - The number of days after which the memory's events expire (3-365), used
# when the connector creates the resource. Ignored if the resource already exists
# + description - An optional description, used when the connector creates the resource
# + encryptionKeyArn - The ARN of a customer-managed AWS KMS key to encrypt the memory with, used
# when the connector creates the resource. If omitted, AgentCore's default encryption is used
# + tags - Optional tags to apply when the connector creates the resource
@display {label: "Memory Resource Configuration"}
public type MemoryResourceConfig record {|
    @display {label: "Memory Name"}
    string memoryName = "chat_memory";
    @display {label: "Create Memory If Not Exists"}
    boolean createMemoryIfNotExists = true;
    @display {label: "Event Expiry Duration (Days)"}
    int eventExpiryDuration = 90;
    @display {label: "Description"}
    string description?;
    @display {label: "Encryption Key ARN"}
    string encryptionKeyArn?;
    @display {label: "Tags"}
    map<string> tags?;
|};
