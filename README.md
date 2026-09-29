# ballerina-ai-memory-for-bedrock-agentcore

`ballerinax/ai.aws.agentcore` is a [Ballerina](https://ballerina.io/) package that provides an [Amazon Bedrock AgentCore Memory](https://docs.aws.amazon.com/bedrock-agentcore/latest/APIReference/Welcome.html)-backed `ai:Memory` for [`ballerina/ai`](https://central.ballerina.io/ballerina/ai/latest) agents.

## Overview

- An `ai:Memory` (`agentcore:Memory`) that stores each agent turn as a single AgentCore event: a lossless JSON envelope for exact replay, alongside plain-text items for AgentCore's own extraction strategies
- `get` folds a session's events back into one message list, tolerating events written by other SDKs sharing the same memory resource
- Durable human-in-the-loop checkpoints (`putCheckpoint`/`getCheckpoint`/`removeCheckpoint`/`takeCheckpoint`), so a run paused for approval survives a restart or resumes on another replica
- Two delete modes: `SOFT` (an instant reset marker) and `PHYSICAL` (rate-limited removal of every prior event)
- SigV4 request signing and AWS credential resolution via `ballerinax/aws.auth` (the default credential provider chain, static credentials, profiles, assume-role, web identity, SSO, or an external credential process)

## Prerequisites

- An AWS account with an [AgentCore Memory resource](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/memory.html) already created, and credentials that grant `bedrock-agentcore:CreateEvent` and `bedrock-agentcore:ListEvents`. `bedrock-agentcore:DeleteEvent` is additionally needed for `PHYSICAL` delete and for human-in-the-loop checkpoints (tools that require approval), and `bedrock-agentcore:GetMemory` for `verifyMemory`.
- Creating and configuring the memory resource itself (extraction strategies, namespaces, `eventExpiryDuration`) is out of scope for this package - use the AWS Console, CLI, or IaC.
- A local [Ballerina](https://ballerina.io/downloads/) installation to build this package from source.

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

Either mode also removes the session's pending human-in-the-loop checkpoint, if any.

## Human-in-the-loop checkpoints

When an `ai:Agent` tool requires approval, the agent pauses and persists its state through the memory's checkpoint methods. `agentcore:Memory` stores that checkpoint in AgentCore itself, so a paused run survives a restart and can be resumed on another replica - no extra configuration is needed.

- A checkpoint lives in its own AgentCore session under the same actor, derived from the conversation session. It never appears in `get`'s history and never uses up `maxEventsPerGet`. Session ids starting with `ckpt--` are reserved for this and rejected.
- `takeCheckpoint` claims a checkpoint by deleting its event, so if several resumes for the same session race, only one gets the pending approval; the others get `()`. This relies on AgentCore's `DeleteEvent` rejecting a second delete of the same event.

## Error handling

Every failure from this package is an `agentcore:Error` (`distinct ai:MemoryError & error<aws:ErrorDetails>`), so it can be caught either as this package's own error type or as the generic `ai:MemoryError` that `ai:Memory` implementations are expected to return. `error<aws:ErrorDetails>` fields (`httpStatusCode`, `errorCode`, `requestId`, ...) are populated when the failure came back from AWS, and left unset for local failures (invalid configuration, credential resolution, request signing). Note that `ai:Agent` itself only logs `ai:Memory` failures at debug level rather than surfacing them to the caller - this package logs every AgentCore call failure at `WARN` (with the AWS request id, when available) so it is still visible to an operator.

## Build from the source

The Ballerina package lives in [`ballerina/`](ballerina); the repository root holds the Gradle build and CI configuration around it. The tests run entirely against an in-process mock of the AgentCore API - no AWS account or network access is required. There is no live test suite in this repository yet.

### Setting up the prerequisites

1. Download and install Java SE Development Kit (JDK) version 21, from either [Oracle JDK](https://www.oracle.com/java/technologies/downloads/) or [OpenJDK](https://adoptium.net/), and set the `JAVA_HOME` environment variable to its installation directory.

2. Download and install [Ballerina Swan Lake](https://ballerina.io/).

3. Export a GitHub personal access token with the `read:packages` permission, which the build uses to fetch the Ballerina Gradle plugin:

    ```bash
    export packageUser=<Username>
    export packagePAT=<Personal access token>
    ```

### Build options

1. To build the package:

   ```bash
   ./gradlew clean build
   ```

2. To run the tests:

   ```bash
   ./gradlew clean test
   ```

3. To build without the tests:

   ```bash
   ./gradlew clean build -x test
   ```

4. To publish the generated artifacts to the local Ballerina Central repository:

   ```bash
   ./gradlew clean build -PpublishToLocalCentral=true
   ```

To iterate on the package alone without Gradle, run `bal build` and `bal test` from inside `ballerina/`.

## Issues

Report bugs and feature requests through this repository's [issue tracker](https://github.com/SahanjithD/ballerina-ai-memory-for-bedrock-agentcore/issues).

## License

Apache License 2.0 - see [LICENSE](LICENSE).
