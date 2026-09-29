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
import ballerina/lang.runtime;

// `CreateMemory` requires a name matching this pattern, unique within the account and region.
final regexp:RegExp & readonly MEMORY_NAME_PATTERN = re `^[a-zA-Z][a-zA-Z0-9_]{0,47}$`;

// `CreateMemory` accepts 3-365 days.
const int MIN_EVENT_EXPIRY_DAYS = 3;
const int MAX_EVENT_EXPIRY_DAYS = 365;

// Creation is asynchronous: `CreateMemory` returns `CREATING` and the resource becomes usable once
// `GetMemory` reports `ACTIVE`. 120 polls x 5s = 10 minutes, the same overall budget the DynamoDB
// memory store gives a new table - generous for a first create, while a 5s interval keeps the
// number of control-plane calls low.
const int MAX_ACTIVATION_POLLS = 120;
const decimal ACTIVATION_POLL_INTERVAL_SECONDS = 5;

isolated function validateMemoryResourceConfig(MemoryResourceConfig config) returns Error? {
    if !MEMORY_NAME_PATTERN.isFullMatch(config.memoryName) {
        return error Error(string `Invalid memory name: '${config.memoryName}'. It must start with a letter ` +
            "and contain only letters, digits, and underscores, at most 48 characters.");
    }
    if config.eventExpiryDuration < MIN_EVENT_EXPIRY_DAYS || config.eventExpiryDuration > MAX_EVENT_EXPIRY_DAYS {
        return error Error(string `Invalid eventExpiryDuration: '${config.eventExpiryDuration}'. ` +
            string `It must be between ${MIN_EVENT_EXPIRY_DAYS} and ${MAX_EVENT_EXPIRY_DAYS} days.`);
    }
}

// Finds the memory resource named `memoryName`, creating it if allowed and absent, and waits until
// it is `ACTIVE`. Returns its id.
isolated function resolveMemoryId(MemoryClient agentCoreClient, MemoryResourceConfig config,
        decimal pollIntervalSeconds = ACTIVATION_POLL_INTERVAL_SECONDS) returns string|Error {
    string? existingId = check findMemoryIdByName(agentCoreClient, config.memoryName);
    if existingId is string {
        check waitForMemoryActive(agentCoreClient, existingId, pollIntervalSeconds);
        return existingId;
    }
    if !config.createMemoryIfNotExists {
        return error Error(string `No AgentCore Memory resource named '${config.memoryName}' exists, and ` +
            "createMemoryIfNotExists is false.");
    }

    ControlPlaneMemory|Error created = agentCoreClient->createMemory(config.memoryName, config.eventExpiryDuration,
        config?.description, config?.encryptionKeyArn, config?.tags);
    if created is Error {
        if created.detail().httpStatusCode != 409 {
            return error Error(string `Failed to create the AgentCore Memory resource '${config.memoryName}': ` +
                created.message(), created);
        }
        // Names are unique per account, so a conflict means another initializer (e.g. a second
        // replica starting at the same time) created it first - the same case the DynamoDB store
        // handles for `ResourceInUse`. Look it up again and use theirs.
        string? racedId = check findMemoryIdByName(agentCoreClient, config.memoryName);
        if racedId is () {
            return error Error(string `An AgentCore Memory resource named '${config.memoryName}' already exists, ` +
                "but it could not be found by name; set MemoryConfig.memoryId to its id instead.", created);
        }
        check waitForMemoryActive(agentCoreClient, racedId, pollIntervalSeconds);
        return racedId;
    }
    check waitForMemoryActive(agentCoreClient, created.id, pollIntervalSeconds);
    return created.id;
}

// `ListMemories` returns ids and statuses but not names. AgentCore builds a memory's id from its
// name plus a hyphen and a 10-character suffix, and names cannot contain hyphens, so an id of
// exactly that shape can only belong to that name. Each candidate is still confirmed against the
// `name` `GetMemory` reports before it is used. If AgentCore ever stopped deriving ids this way,
// the lookup would find nothing and `CreateMemory` would fail with a name conflict (handled in
// `resolveMemoryId`) rather than silently creating a duplicate.
isolated function findMemoryIdByName(MemoryClient agentCoreClient, string memoryName) returns string?|Error {
    string? nextToken = ();
    while true {
        ListMemoriesResponse|Error page = agentCoreClient->listMemories(nextToken);
        if page is Error {
            return error Error("Failed to list AgentCore Memory resources: " + page.message(), page);
        }
        foreach MemorySummary summary in page.memories {
            if !isIdForName(summary.id, memoryName) {
                continue;
            }
            ControlPlaneMemory|Error details = agentCoreClient->getMemory(summary.id);
            if details is Error {
                return error Error(string `Failed to read the AgentCore Memory resource '${summary.id}': ` +
                    details.message(), details);
            }
            string? name = details?.name;
            if name is () || name == memoryName {
                return summary.id;
            }
        }
        nextToken = page?.nextToken;
        if nextToken is () {
            return ();
        }
    }
}

final regexp:RegExp & readonly MEMORY_ID_SUFFIX_PATTERN = re `^[a-zA-Z0-9]{10}$`;

isolated function isIdForName(string memoryId, string memoryName) returns boolean {
    string prefix = memoryName + "-";
    return memoryId.startsWith(prefix) && MEMORY_ID_SUFFIX_PATTERN.isFullMatch(memoryId.substring(prefix.length()));
}

// Polls until the memory is `ACTIVE`. Right after `CreateMemory` the control plane can briefly
// report the new memory as not found (it is eventually consistent), so a 404 is re-polled within
// the same budget; `FAILED` and `DELETING` are terminal. Throttling and server faults are already
// retried inside `MemoryClient`.
isolated function waitForMemoryActive(MemoryClient agentCoreClient, string memoryId, decimal pollIntervalSeconds)
        returns Error? {
    string lastStatus = "unknown";
    foreach int _ in 0 ..< MAX_ACTIVATION_POLLS {
        ControlPlaneMemory|Error details = agentCoreClient->getMemory(memoryId);
        if details is Error {
            if details.detail().httpStatusCode != 404 {
                return error Error(string `Failed to check the status of the AgentCore Memory resource ` +
                    string `'${memoryId}': ${details.message()}`, details);
            }
        } else {
            lastStatus = details.status;
            if lastStatus == "ACTIVE" {
                return;
            }
            if lastStatus == "FAILED" {
                string reason = details?.failureReason ?: "no failure reason reported";
                return error Error(string `The AgentCore Memory resource '${memoryId}' failed: ${reason}`);
            }
            if lastStatus == "DELETING" {
                return error Error(string `The AgentCore Memory resource '${memoryId}' is being deleted.`);
            }
        }
        runtime:sleep(pollIntervalSeconds);
    }
    return error Error(string `The AgentCore Memory resource '${memoryId}' did not become active within the ` +
        string `expected time (last status: ${lastStatus}).`);
}
