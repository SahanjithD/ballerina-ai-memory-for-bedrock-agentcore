## Overview

This package provides an [Amazon Bedrock AgentCore Memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/APIReference/Welcome.html)-backed `ai:Memory` for `ballerina/ai` agents, plus a long-term-memory recall toolkit built on the same resource.

### Key Features

- An `ai:Memory` (`agentcore:Memory`) that stores each agent turn as a single AgentCore event: a lossless JSON envelope for exact replay, alongside plain-text items for AgentCore's own extraction strategies
- `get` folds a session's events back into one message list, tolerating events written by other SDKs sharing the same memory resource
- Two delete modes: `SOFT` (an instant reset marker) and `PHYSICAL` (rate-limited removal of every prior event)
- `LongTermMemoryToolKit`, a tool-based recall toolkit the LLM calls explicitly to search AgentCore's extracted long-term memory records across one or more namespaces
- `RecallAugmentedMemory`, an optional, off-by-default wrapper that searches long-term memory on every turn instead of waiting for a tool call
- `MemoryClient`, a lower-level typed client over AgentCore's `CreateEvent`/`ListEvents`/`DeleteEvent`/`RetrieveMemoryRecords`/`GetMemory` operations, for anything the higher-level types don't cover
- SigV4 request signing and AWS credential resolution via `ballerinax/aws.auth` (the default credential provider chain, static credentials, profiles, assume-role, web identity, SSO, or an external credential process)

## Prerequisites

- An AWS account with an [AgentCore Memory resource](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html) already created, and credentials that grant `bedrock-agentcore:CreateEvent`, `bedrock-agentcore:ListEvents`, and (if using `PHYSICAL` delete or `LongTermMemoryToolKit`/`RecallAugmentedMemory`) `bedrock-agentcore:DeleteEvent` and `bedrock-agentcore:RetrieveMemoryRecords` respectively. `verifyMemory` additionally needs `bedrock-agentcore:GetMemory`.
- Creating and configuring the memory resource itself (extraction strategies, namespaces, `eventExpiryDuration`) is out of scope for this package - use the AWS Console, CLI, or IaC.

## Quickstart

### 1. Import the module

```ballerina
import ballerinax/ai.aws.agentcore;
```

### 2. Create the memory

`sessionKeyConfig` tells the connector how to derive AgentCore's `actorId`/`sessionId` pair from the single session key `ai:Memory` is given. Use `agentcore:FixedActorSessionKeyConfig` when every session in the application belongs to one actor:

```ballerina
configurable string region = ?;
configurable string memoryId = ?;

ai:Memory memory = check new agentcore:Memory({
    region,
    memoryId,
    sessionKeyConfig: {actorId: "my-agent"}
});
```

or `agentcore:CompositeSessionKeyConfig` when the session key itself already encodes both, e.g. a session key of `"user-42/chat-7"`:

```ballerina
ai:Memory memory = check new agentcore:Memory({
    region,
    memoryId,
    sessionKeyConfig: {separator: "/"}
});
```

By default, credentials are resolved from the standard AWS credential provider chain (environment variables, `~/.aws/credentials`, an EC2/ECS/EKS instance role, etc.) - pass `auth` to use a different source (see `ballerinax/aws.auth`'s documentation for the full list):

```ballerina
configurable string accessKeyId = ?;
configurable string secretAccessKey = ?;

ai:Memory memory = check new agentcore:Memory({
    region,
    memoryId,
    sessionKeyConfig: {actorId: "my-agent"},
    auth: {accessKeyId, secretAccessKey}
});
```

### 3. Use it with an `ai:Agent`

```ballerina
ai:Agent agent = check new ({
    systemPrompt: {role: "AI Assistant", instructions: "..."},
    model,
    memory
});
```

Every call to `agent.run(sessionId, query)` reads the session's prior turns from AgentCore and, once the run completes, writes the new turn back as one event.

### 4. Optionally, add long-term memory recall

`LongTermMemoryToolKit` exposes a tool the LLM can call explicitly to search AgentCore's extracted long-term memory records:

```ballerina
agentcore:LongTermMemoryToolKit longTermMemory = check new (
    {region, auth: {accessKeyId, secretAccessKey}},
    memoryId,
    namespaces = ["/facts/{actorId}"],
    namespaceVariables = {"actorId": "user-42"}
);

ai:Agent agent = check new ({
    systemPrompt,
    model,
    memory,
    tools: [longTermMemory]
});
```

## Storage model

Each `ai:Memory.update` call - one per completed agent turn - is written as a single AgentCore event whose `payload` carries two kinds of items:

| Item | Purpose |
|---|---|
| One `blob` item | A lossless JSON envelope of every message in the turn (including the system and user messages, tool calls, and tool results). This is the only thing `get` reads back - it is what makes replay exact. |
| Zero or more `conversational` items | Plain-text renderings of the turn's user/assistant/tool-result content, for AgentCore's own extraction strategies (summarization, semantic facts, etc.) to work on. Never read back by this module. |

`get` calls `ListEvents` (AWS documents no ordering guarantee for it, so results are always sorted client-side by timestamp), decodes every event's blob, and folds them into one message list - keeping only the most recently written system message, since `ai:Agent` resends the same system message on every turn. Events whose blob isn't one this module's version recognizes (a different writer sharing the memory resource, or an incompatible envelope version) are skipped rather than failing the whole read.

`delete` supports two modes, set via `deleteMode` (defaults to `SOFT`):

- **`SOFT`** writes a reset-marker event; `get` then treats everything before it as void. Prior events remain in AgentCore until `eventExpiryDuration` expires. Cheap and instant - the default for a reason.
- **`PHYSICAL`** does the same, then also issues `DeleteEvent` for every prior event, rate-limited client-side to stay well under AgentCore's account-level quota.

## Optional recall injection

`RecallAugmentedMemory` wraps an existing `ai:Memory` to search long-term memory on *every* `get` call and append the results as a trailing message, rather than waiting for the LLM to call a tool:

```ballerina
ai:Memory memory = check new agentcore:Memory({region, memoryId, sessionKeyConfig: {actorId: "my-agent"}});
ai:Memory recallMemory = check new agentcore:RecallAugmentedMemory(
    memory,
    {region, auth: {accessKeyId, secretAccessKey}},
    memoryId,
    namespaces = ["/facts/{actorId}"],
    namespaceVariables = {"actorId": "user-42"}
);

ai:Agent agent = check new ({systemPrompt, model, memory: recallMemory});
```

This is **off by default** - most applications should reach for `LongTermMemoryToolKit` instead, and use this only when the LLM should never have to decide whether to search. Two trade-offs come with it: the query searched is always the *previous* turn's user message (`ai:Memory.get` has no way to see the query for the turn currently being run), and it costs one `RetrieveMemoryRecords` call per configured namespace on every single turn, whether or not the result ends up being useful.

## Error handling

Every failure from this package is an `agentcore:Error` (`distinct ai:MemoryError & error<aws:ErrorDetails>`), so it can be caught either as this package's own error type or as the generic `ai:MemoryError` that `ai:Memory`/`ai:BaseToolKit` implementations are expected to return. `error<aws:ErrorDetails>` fields (`httpStatusCode`, `errorCode`, `requestId`, ...) are populated when the failure came back from AWS, and left unset for local failures (invalid configuration, credential resolution, request signing). Note that `ai:Agent` itself only logs `ai:Memory` failures at debug level rather than surfacing them to the caller - this package logs every AgentCore call failure at `WARN` (with the AWS request id, when available) so it is still visible to an operator.
