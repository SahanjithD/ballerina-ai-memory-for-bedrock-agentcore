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

// Resolves `{variable}` placeholders in a namespace template against a fixed set of static
// substitutions. A literal `*` in the template needs no special handling here - it is just an
// ordinary character that passes through unresolved, and AgentCore itself interprets it as a
// wildcard on the `namespace`/`namespacePath` search parameters.
isolated function resolveNamespace(string template, map<string> variables) returns string|Error {
    string result = "";
    int i = 0;
    while i < template.length() {
        if template.substring(i, i + 1) != "{" {
            result += template.substring(i, i + 1);
            i += 1;
            continue;
        }
        int? closeIndex = template.indexOf("}", i);
        if closeIndex is () {
            return error Error(string `Invalid namespace template '${template}': unterminated '{' at index ${i}.`);
        }
        string variableName = template.substring(i + 1, closeIndex);
        string? value = variables[variableName];
        if value is () {
            return error Error(string `Namespace template '${template}' references undefined variable ` +
                string `'${variableName}'.`);
        }
        result += value;
        i = closeIndex + 1;
    }
    return result;
}
