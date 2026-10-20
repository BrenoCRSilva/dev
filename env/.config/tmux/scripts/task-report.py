#!/usr/bin/env python3
"""Check a task step report (C4) before its agent reports it.

    task-report.py check <task-root>/reports/<agent>/<step>.json

Validates the file against task-roles/report.schema.json and checks that its
path names the same agent and step as its contents. Prints each problem and
exits 1; exits 0 and prints "ok" when the report is valid; exits 2 on bad
usage. Stdlib only. The schema subset is what the schema uses: type, required,
properties, additionalProperties, items, minLength, maxLength, maxLines,
minItems, maxItems, minimum, maximum and pattern. maxLines counts the lines of
a string (not in JSON Schema; other validators ignore it).
"""
import json
import re
import sys
from pathlib import Path

SCHEMA = Path(__file__).resolve().parent / "task-roles" / "report.schema.json"
TYPES = {
    "string": str,
    "integer": int,
    "array": list,
    "object": dict,
    "boolean": bool,
    "null": type(None),
}


def is_type(value, name):
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    return isinstance(value, TYPES[name])


def check(value, schema, where, errors):
    types = schema.get("type")
    if types is not None:
        names = types if isinstance(types, list) else [types]
        if not any(is_type(value, name) for name in names):
            errors.append(f"{where}: expected {' or '.join(names)}")
            return
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            errors.append(f"{where}: shorter than {schema['minLength']} characters")
        if len(value) > schema.get("maxLength", len(value)):
            errors.append(f"{where}: longer than {schema['maxLength']} characters")
        if len(value.splitlines()) > schema.get("maxLines", len(value.splitlines())):
            errors.append(f"{where}: more than {schema['maxLines']} lines")
        # Whole-value match: a plain $ would also accept a trailing newline.
        if "pattern" in schema and not re.fullmatch(schema["pattern"], value):
            errors.append(f"{where}: does not match {schema['pattern']}")
    if is_type(value, "integer"):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{where}: below {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{where}: above {schema['maximum']}")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{where}: fewer than {schema['minItems']} items")
        if len(value) > schema.get("maxItems", len(value)):
            errors.append(f"{where}: more than {schema['maxItems']} items")
        for index, item in enumerate(value):
            check(item, schema.get("items", {}), f"{where}[{index}]", errors)
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{where}: missing {key}")
        for key, item in value.items():
            if key in props:
                check(item, props[key], f"{where}.{key}", errors)
            elif schema.get("additionalProperties", True) is False:
                errors.append(f"{where}: unknown field {key}")


def problems(report, path=None):
    """Schema problems, and path problems when a path is given."""
    errors = []
    check(report, json.loads(SCHEMA.read_text(encoding="utf-8")), "report", errors)
    if path is not None and isinstance(report, dict):
        # The path must name the same agent and step as the contents.
        if path.parent.parent.name != "reports":
            errors.append("path: report is not under reports/<agent>/")
        if path.parent.name != report.get("agent") or path.name != f"{report.get('step')}.json":
            errors.append("path: file must be reports/<agent>/<step>.json for its agent and step")
    return errors


def main(argv):
    if len(argv) != 2 or argv[0] != "check":
        print("usage: task-report.py check <task-root>/reports/<agent>/<step>.json", file=sys.stderr)
        return 2
    path = Path(argv[1])
    try:
        report = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"{path}: cannot read as JSON: {error}")
        return 1
    errors = problems(report, path)
    for error in errors:
        print(f"{path}: {error}")
    if errors:
        return 1
    print(f"ok {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
