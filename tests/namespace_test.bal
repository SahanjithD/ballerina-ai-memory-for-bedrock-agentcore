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

@test:Config
function testResolveNamespaceSubstitutesVariables() returns error? {
    test:assertEquals(check resolveNamespace("/facts/{actorId}", {"actorId": "user-42"}), "/facts/user-42");
    test:assertEquals(check resolveNamespace("{a}/{b}", {"a": "x", "b": "y"}), "x/y");
    test:assertEquals(check resolveNamespace("{a}{a}", {"a": "x"}), "xx");
}

@test:Config
function testResolveNamespacePassesLiteralsThrough() returns error? {
    test:assertEquals(check resolveNamespace("/facts/user-42", {}), "/facts/user-42");
    test:assertEquals(check resolveNamespace("", {}), "");
}

@test:Config
function testWildcardSegmentsPassThrough() returns error? {
    // `*` is AgentCore's own wildcard on `namespace`/`namespacePath`; it needs no escaping here.
    test:assertEquals(check resolveNamespace("/facts/*", {}), "/facts/*");
    test:assertEquals(check resolveNamespace("/facts/{actorId}/*", {"actorId": "user-42"}), "/facts/user-42/*");
    test:assertEquals(check resolveNamespace("/*/{kind}/*", {"kind": "prefs"}), "/*/prefs/*");
}

@test:Config
function testUndefinedVariableIsAnError() {
    string|Error resolved = resolveNamespace("/facts/{actorId}", {});
    test:assertTrue(resolved is Error);
    test:assertTrue((<Error>resolved).message().includes("undefined variable 'actorId'"));

    test:assertTrue(resolveNamespace("/facts/{a}/{b}", {"a": "x"}) is Error);
    test:assertTrue(resolveNamespace("{}", {}) is Error, "an empty variable name is still undefined");
}

@test:Config
function testUnterminatedPlaceholderIsAnError() {
    string|Error resolved = resolveNamespace("/facts/{actorId", {"actorId": "user-42"});
    test:assertTrue(resolved is Error);
    test:assertTrue((<Error>resolved).message().includes("unterminated"));
}

@test:Config
function testSubstitutionIsNotRecursive() returns error? {
    // A substituted value is never re-scanned for placeholders, so a variable value cannot smuggle
    // in a second round of substitution.
    test:assertEquals(check resolveNamespace("/facts/{actorId}", {"actorId": "{admin}"}), "/facts/{admin}");
    test:assertEquals(check resolveNamespace("/facts/{actorId}", {"actorId": "{actorId}"}), "/facts/{actorId}");
}
