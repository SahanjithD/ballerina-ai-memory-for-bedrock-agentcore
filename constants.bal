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

// The SigV4 signing name and endpoint-resolution service prefix for the AgentCore Memory
// data-plane API (CreateEvent, ListEvents, DeleteEvent, RetrieveMemoryRecords).
const string DATA_PLANE_SERVICE = "bedrock-agentcore";

// The SigV4 signing name and endpoint-resolution service prefix for the AgentCore control-plane
// API. Only `GetMemory` (used by `verifyMemory`) is called against this host.
const string CONTROL_PLANE_SERVICE = "bedrock-agentcore-control";

// `CreateEvent.payload` accepts at most 100 items. Every event this module writes carries exactly
// one blob item (the lossless envelope of the whole turn), so the conversational items rendered
// for AWS's own extraction strategies must be capped at 99, not 100.
const int MAX_PAYLOAD_ITEMS = 100;
const int MAX_CONVERSATIONAL_ITEMS_PER_EVENT = MAX_PAYLOAD_ITEMS - 1;

// `CreateEvent`/`Event.metadata` accepts at most 15 entries.
const int MAX_EVENT_METADATA_ENTRIES = 15;

// `ListEvents.maxResults` and `RetrieveMemoryRecords.maxResults` both accept 1-100; both default
// to 20 server-side when omitted. This module always requests the maximum page size so a plain
// turn's read-back stays within a single `ListEvents` call whenever possible.
const int MAX_PAGE_SIZE = 100;

// Retry policy for transient AgentCore failures (throttling, 5xx, retryable conflicts):
// 3 retries, 1s initial backoff, factor 2, 20s ceiling, full jitter.
const int MAX_RETRY_ATTEMPTS = 3;
const decimal INITIAL_BACKOFF_SECONDS = 1;
const decimal BACKOFF_FACTOR = 2;
const decimal MAX_BACKOFF_SECONDS = 20;

// AWS Conversational.role values.
const string ROLE_USER = "USER";
const string ROLE_ASSISTANT = "ASSISTANT";
const string ROLE_TOOL = "TOOL";
const string ROLE_OTHER = "OTHER";

// EventMetadataFilterExpression/MemoryMetadataFilterExpression operator values.
const string OPERATOR_EQUALS_TO = "EQUALS_TO";
