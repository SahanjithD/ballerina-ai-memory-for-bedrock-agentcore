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

import ballerina/test;

const string SAMPLE_EVENT_ID = "0000001758000000000#a1b2c3d4";

@test:Config
function testDataPlanePaths() {
    test:assertEquals(createEventPath("mem-1"), "/memories/mem-1/events");
    test:assertEquals(listEventsPath("mem-1", "user-42", "chat-7"),
            "/memories/mem-1/actor/user-42/sessions/chat-7");
    test:assertEquals(getMemoryPath("mem-1"), "/memories/mem-1/details");
}

@test:Config
function testDeleteEventSignerPathKeepsTheHashRaw() {
    // `aws.auth:SignatureRequest.path` is documented unencoded - the signer does its own
    // canonicalization, so pre-encoding here would sign a different path than AWS computes.
    string signerPath = deleteEventSignerPath("mem-1", "user-42", "chat-7", SAMPLE_EVENT_ID);
    test:assertEquals(signerPath,
            string `/memories/mem-1/actor/user-42/sessions/chat-7/events/${SAMPLE_EVENT_ID}`);
    test:assertTrue(signerPath.includes("#"));
    test:assertFalse(signerPath.includes("%23"));
}

@test:Config
function testDeleteEventHttpPathEncodesTheHash() {
    // Left raw, `#` is a fragment delimiter: everything after it would be dropped from the
    // request line, so the server would see a truncated event id.
    string httpPath = deleteEventHttpPath("mem-1", "user-42", "chat-7", SAMPLE_EVENT_ID);
    test:assertEquals(httpPath, "/memories/mem-1/actor/user-42/sessions/chat-7/events/0000001758000000000%23a1b2c3d4");
    test:assertFalse(httpPath.includes("#"));
}

@test:Config
function testDeleteEventPathsDifferOnlyInTheHashEncoding() {
    string signerPath = deleteEventSignerPath("mem-1", "user-42", "chat-7", SAMPLE_EVENT_ID);
    string httpPath = deleteEventHttpPath("mem-1", "user-42", "chat-7", SAMPLE_EVENT_ID);
    test:assertNotEquals(signerPath, httpPath, "swapping these two breaks either routing or the signature");
    test:assertEquals(re `%23`.replaceAll(httpPath, "#"), signerPath);
}

@test:Config
function testDeleteEventPathsWithoutAHashAreIdentical() {
    // A hypothetical hash-free event id must not be mangled.
    string plainId = "0000001758000000000";
    test:assertEquals(deleteEventHttpPath("mem-1", "a", "b", plainId),
            deleteEventSignerPath("mem-1", "a", "b", plainId));
}

@test:Config
function testEveryHashInAnEventIdIsEncoded() {
    test:assertEquals(deleteEventHttpPath("m", "a", "b", "1#2#3"), "/memories/m/actor/a/sessions/b/events/1%232%233");
}
