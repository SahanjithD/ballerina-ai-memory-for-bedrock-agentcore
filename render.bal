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

// Renders a `string|ai:Prompt` message content into plain text, for the `conversational` payload
// items sent alongside the lossless blob envelope (see `envelope.bal`). AgentCore's extraction
// strategies only ever see this plain-text rendering - the blob, not these items, is what `get`
// decodes back into `ai:ChatMessage`s, so a lossy rendering here only affects what AWS extracts
// from, never what the agent reads back.
isolated function renderContent(string|ai:Prompt content) returns string {
    if content is string {
        return content;
    }
    string[] & readonly strings = content.strings;
    anydata[] insertions = content.insertions;
    string rendered = "";
    foreach int i in 0 ..< strings.length() {
        rendered += strings[i];
        if i < insertions.length() {
            rendered += insertions[i].toString();
        }
    }
    return rendered;
}
