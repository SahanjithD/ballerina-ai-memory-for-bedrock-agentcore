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

// `ai:ChatMessage` is not `anydata` (`ai:Prompt` is an object), so it cannot be handed to
// `test:assertEquals` directly. Canonicalizing through the module's own JSON-safe stored form gives
// comparable values without losing any field, including `Prompt` content.
isolated function asJson(ai:ChatMessage[] messages) returns json =>
    (from ai:ChatMessage message in messages select toDatabaseMessage(message)).toJson();

isolated function repeatString(string unit, int times) returns string {
    string[] parts = [];
    foreach int _ in 0 ..< times {
        parts.push(unit);
    }
    return "".'join(...parts);
}

isolated function userContent(ai:ChatMessage message) returns string {
    string|ai:Prompt content = (<ai:ChatUserMessage>message).content;
    return content is string ? content : renderContent(content);
}
