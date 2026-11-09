#!/usr/bin/env python3
"""Check bundled zh/en messages and literal L(...) calls without a Swift build."""
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources/CmuxClone/Localization/messages.json"


def string_literal(source, start):
    index, template, arguments = start + 1, "", 0
    while index < len(source):
        char = source[index]
        if char == '"':
            return index + 1, template
        if source.startswith("\\(", index):
            end, depth = index + 2, 1
            while depth:
                if source[end] == '"':
                    end, _ = string_literal(source, end)
                    continue
                if source[end] == "(":
                    depth += 1
                elif source[end] == ")":
                    depth -= 1
                end += 1
            # Nested translated expressions are checked separately by scan().
            template += "{" + str(arguments) + "}"
            arguments += 1
            index = end
        elif char == "\\":
            escape = source[index:index + 2]
            template += {"\\n": "\n", "\\r": "\r", "\\t": "\t", '\\"': '"', "\\\\": "\\"}.get(escape, escape)
            index += 2
        else:
            template += char
            index += 1
    raise ValueError("Unterminated Swift string")


def scan(source):
    # L accepts a typed interpolation, so every call must use a literal template.
    for match in re.finditer(r'\bL\("', source):
        _, template = string_literal(source, match.end() - 1)
        yield source.count("\n", 0, match.start()) + 1, template


def main():
    messages = json.loads(CATALOG.read_text())
    sources, errors = set(), []
    for key, entry in messages.items():
        if set(entry) != {"zh", "en"} or not all(entry.values()):
            errors.append(f"{key}: must contain nonempty zh and en values")
            continue
        if entry["zh"] in sources:
            errors.append(f"{key}: duplicate source template")
        sources.add(entry["zh"])
        if re.search(r"[\u3400-\u9fff]", entry["en"]):
            errors.append(f"{key}: untranslated Chinese text in English")
        if Counter(re.findall(r"\{\d+\}", entry["zh"])) != Counter(re.findall(r"\{\d+\}", entry["en"])):
            errors.append(f"{key}: parameter mismatch")
    calls = 0
    for path in sorted((ROOT / "Sources/CmuxClone").glob("*.swift")):
        for line, template in scan(path.read_text()):
            calls += 1
            if template not in sources:
                errors.append(f"{path.relative_to(ROOT)}:{line}: missing message {template!r}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Localization OK: {len(messages)} bilingual messages, {calls} source calls")
    return 0


if __name__ == "__main__":
    sys.exit(main())
