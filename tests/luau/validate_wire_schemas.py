"""Validate captured offline requests with the standard JSON Schema validator.

Requires jsonschema; run from the package root after the Luau harness.
"""
import json
from pathlib import Path

from jsonschema import Draft202012Validator

fixtures = json.loads(Path(__file__).with_name("tool-request-fixtures.json").read_text())
total = 0
for fixture in fixtures:
    protocol, body = fixture["protocol"], fixture["body"]
    if protocol == "gemini_native":
        definitions, key = body["tools"][0]["functionDeclarations"], "parameters"
    elif protocol == "anthropic_messages":
        definitions, key = body["tools"], "input_schema"
    elif protocol == "openai_responses":
        definitions, key = body["tools"], "parameters"
    else:
        definitions, key = [item["function"] for item in body["tools"]], "parameters"
    for tool in definitions:
        schema = tool[key]
        Draft202012Validator.check_schema(schema)
        assert isinstance(schema["properties"], dict), (protocol, tool["name"])
        assert isinstance(schema["required"], list), (protocol, tool["name"])
        if not schema["required"]:
            Draft202012Validator(schema).validate({})
        if tool["name"] == "create_ui":
            Draft202012Validator(schema).validate({
                "name": "Fixture",
                "elements": [{"className": "Frame", "name": "Panel"}],
            })
        total += 1
assert len(fixtures) == 12
assert len({fixture['protocol'] for fixture in fixtures}) == 6
print(f"{total} valid tool definitions across 6 protocols and {len(fixtures)} captured requests (including local bridge tools).")
