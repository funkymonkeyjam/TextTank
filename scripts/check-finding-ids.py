#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Resolve first-party source and test finding citations against the curated November audit."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
REGISTER = Path("docs/research/finding-ids.md")
SOURCE_SUFFIXES = {".swift", ".h", ".hpp", ".m", ".mm", ".c", ".cc", ".cpp", ".cxx", ".py", ".sh"}
TOKEN = re.compile(r"\b[FG][0-9]+\b")
ROW = re.compile(r"\| ([FG][1-9][0-9]*) \| (\S(?:.*\S)?) \|")


def other_label(token, path, line, start):
    if token == "F0":
        return path in {"Sources/Compare/CompareCore.swift", "Tests/ReviewCoreChecks.swift", "Tests/ReviewApplierChecks.swift"}
    if token == "F000":
        return path == "Tests/HarnessChecks.swift" and ("knownDefect(" in line or "known defect F000" in line
                                                      or "KNOWN-DEFECT F000 demo" in line or "HarnessDemo:" in line)
    if token == "F702":
        return line[max(0, start - 3):start] == "\\u{" and line[start + len(token):].startswith("}")
    if token in {"G2", "G3", "G4"}:
        return path == "Tests/TabGroupNativeChecks.swift" and ('"T3 ' in line)
    if token in {"F5", "F9"} and path == "Tests/SettingsShortcutValidationChecks.swift":
        # Function keys, as a shortcut is stored, shown and said.
        return "MenuShortcut(f5" in line or "MenuShortcut(f9" in line
    if token == "F9":
        return ((path == "Sources/Documents/EditorCommandCatalog.swift" and "// F9" in line)
                or (path == "Tests/MacroChecks.swift" and ('"F9 starts recording' in line or '"Shift-F9 runs' in line)))
    return False


def check(root):
    definitions = set()
    problems = []
    for n, line in enumerate((root / REGISTER).read_text().splitlines(), 1):
        if not line.startswith(("| F", "| G")):
            continue
        row = ROW.fullmatch(line)
        if row is None or row[1] in definitions:
            problems.append(f"{REGISTER}:{n}: malformed or duplicate audit definition")
        else:
            definitions.add(row[1])
    references, labels = set(), set()
    for directory in ("Sources", "Tests"):
        for file in sorted((root / directory).rglob("*")):
            if file.suffix not in SOURCE_SUFFIXES or {"Boost", "LexUserPort"}.intersection(file.parts):
                continue
            path = file.relative_to(root).as_posix()
            for n, line in enumerate(file.read_text().splitlines(), 1):
                for match in TOKEN.finditer(line):
                    token = match[0]
                    if other_label(token, path, line, match.start()):
                        labels.add(token)
                    else:
                        references.add(token)
                        if token not in definitions:
                            problems.append(f"{path}:{n}: unknown audit finding {token}")
    if not references:
        problems.append("No first-party finding references were checked")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"PASS FindingRegister: {len(references)} referenced audit IDs, {len(labels)} distinct non-audit labels")
    return 0


if __name__ == "__main__":
    sys.exit(check(ROOT))
