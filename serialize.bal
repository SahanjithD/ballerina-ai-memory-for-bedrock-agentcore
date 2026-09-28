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

import ballerina/ai;

// `ai:ChatMessage.content` can be a `string` or an `ai:Prompt` (a raw-template object), and
// `ai:Prompt` is not directly JSON-serializable. These `*DatabaseMessage` types mirror the shape
// of the corresponding `ai:Chat*Message` records with `content` narrowed to a JSON-safe form, so
// the whole turn can round-trip losslessly through the envelope blob. The pattern (and the
// `Prompt` split into `strings`/`insertions`) is the same one `ballerinax/ai.aws.dynamodb` uses
// for the same reason.

type StoredPrompt record {|
    string[] strings;
    anydata[] insertions;
|};

type UserDatabaseMessage record {|
    ai:USER role;
    string|StoredPrompt content;
    string name?;
|};

type SystemDatabaseMessage record {|
    ai:SYSTEM role;
    string|StoredPrompt content;
    string name?;
|};

// `ai:ChatAssistantMessage`/`ai:ChatFunctionMessage` are already JSON-safe as-is.
type DatabaseMessage UserDatabaseMessage|SystemDatabaseMessage|ai:ChatAssistantMessage|ai:ChatFunctionMessage;

isolated function toDatabaseMessage(ai:ChatMessage message) returns DatabaseMessage {
    if message is ai:ChatAssistantMessage|ai:ChatFunctionMessage {
        return message;
    }

    string|StoredPrompt content = toStoredContent(message.content);
    string? name = message?.name;

    if message is ai:ChatUserMessage {
        return name is string ? {role: ai:USER, content, name} : {role: ai:USER, content};
    }
    return name is string ? {role: ai:SYSTEM, content, name} : {role: ai:SYSTEM, content};
}

isolated function fromDatabaseMessage(DatabaseMessage stored) returns ai:ChatMessage {
    if stored is ai:ChatAssistantMessage|ai:ChatFunctionMessage {
        return stored;
    }

    string|ai:Prompt content = fromStoredContent(stored.content);
    string? name = stored?.name;

    if stored is UserDatabaseMessage {
        return name is string ? {role: ai:USER, content, name} : {role: ai:USER, content};
    }
    return name is string ? {role: ai:SYSTEM, content, name} : {role: ai:SYSTEM, content};
}

isolated function toStoredContent(string|ai:Prompt content) returns string|StoredPrompt {
    if content is string {
        return content;
    }
    return {strings: content.strings.clone(), insertions: content.insertions.clone()};
}

isolated function fromStoredContent(string|StoredPrompt content) returns string|ai:Prompt {
    if content is string {
        return content;
    }
    return toPrompt(content.strings.cloneReadOnly(), content.insertions.cloneReadOnly());
}

isolated function toPrompt(string[] & readonly strings, anydata[] & readonly insertions) returns readonly & ai:Prompt =>
    isolated object ai:Prompt {
        public final string[] & readonly strings = strings;
        public final anydata[] & readonly insertions = insertions;
    };
