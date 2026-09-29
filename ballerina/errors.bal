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
import ballerinax/aws;

# Represents a distinct error type for AgentCore memory operations. The `aws:ErrorDetails` fields
# are populated when the failure originates from an AWS service call (a non-2xx HTTP response);
# they are left unset when the failure occurs before a response is received, e.g. an invalid
# configuration or a local validation failure.
public type Error distinct ai:MemoryError & error<aws:ErrorDetails>;
