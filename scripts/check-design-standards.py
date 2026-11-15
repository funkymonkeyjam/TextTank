#!/usr/bin/env python3
"""Guards the countable part of docs/DESIGN-STANDARDS.md.

Each budget in docs/design-budget.json is the most occurrences of a pattern that
Sources/ may contain. A count above its budget fails. A count below it passes
and prints a reminder to lower the budget, so the numbers only ever go down.
The hard rules have no budget: one occurrence fails.

  scripts/check-design-standards.py            check, exit 1 on any failure
  scripts/check-design-standards.py --counts   print the current counts as JSON
  scripts/check-design-standards.py --selftest check the detectors on fixed samples
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
BUDGET = ROOT / "docs" / "design-budget.json"
# Vendored search engine sources are not first-party interface code.
SKIPPED = ("Sources/Search/Boost/",)

RULES = {
    "app_modal_calls": "DS-44",
    "literal_font_sizes": "DS-65",
    "literal_colours": "DS-60",
    "lazy_plurals": "DS-83",
    "beeps": "DS-62",
    "custom_materials": "DS-11",
}
DESTRUCTIVE = re.compile(r'addButton\(withTitle:\s*"((?:Delete|Remove|Discard|Erase|Reset)\b[^"]*)"')
INTERPOLATION = re.compile(r"\\\((?:[^()]|\([^()]*\))*\)")
STRING = re.compile(r'"((?:[^"\\]|\\.)*)"')


def code(line):
    """The line without a trailing or whole-line comment (crude: a // inside a string ends it too,
    which only ever undercounts)."""
    stripped = line.lstrip()
    if stripped.startswith("//"):
        return ""
    return line


def lazy_plurals(line):
    """String literals that say 'file(s)'. An interpolation such as \\(s) is not one."""
    total = 0
    for literal in STRING.findall(line):
        total += len(re.findall(r"[A-Za-z]\(s\)", INTERPOLATION.sub("", literal)))
    return total


def count_line(line):
    text = code(line)
    return {
        "app_modal_calls": len(re.findall(r"\brunModal\(", text)),
        "literal_font_sizes": len(re.findall(r"\bofSize:\s*\d", text)),
        "literal_colours": len(
            re.findall(r"NSColor\(\s*(?:(?:calibrated|srgb|device|displayP3)?[Rr]ed|white|hue|calibratedWhite|genericGamma22White):", text)
        ),
        "lazy_plurals": lazy_plurals(text),
        "beeps": len(re.findall(r"NSSound\.beep\(\)", text)),
        "custom_materials": len(re.findall(r"NSVisualEffectView|titlebarAppearsTransparent\s*=\s*true", text)),
    }


def hard_failures(path, lines):
    failures = []
    for index, line in enumerate(lines):
        text = code(line)
        match = DESTRUCTIVE.search(text)
        if match and not match.group(1).endswith("…") and "design-ok:" not in line:
            window = "".join(lines[index : index + 4])
            if "hasDestructiveAction" not in window:
                failures.append(
                    f"{path}:{index + 1}: the button “{match.group(1)}” is not marked hasDestructiveAction (DS-41)"
                )
        if re.search(r"tabbingMode\s*=\s*\.(preferred|automatic)\b", text):
            failures.append(f"{path}:{index + 1}: native window tabbing is rejected (DS-D1)")
    return failures


def scan():
    counts = {key: 0 for key in RULES}
    failures = []
    files = 0
    for path in sorted(SOURCES.rglob("*")):
        relative = path.relative_to(ROOT).as_posix()
        if path.suffix not in (".swift", ".mm", ".m") or relative.startswith(SKIPPED):
            continue
        files += 1
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        for line in lines:
            for key, value in count_line(line).items():
                counts[key] += value
        if path.suffix == ".swift":
            failures += hard_failures(relative, lines)
    return counts, failures, files


def selftest():
    cases = [
        (count_line('alert.runModal()\n')["app_modal_calls"], 1),
        (count_line('// alert.runModal()\n')["app_modal_calls"], 0),
        (count_line('x.font = .systemFont(ofSize: 11)\n')["literal_font_sizes"], 1),
        (count_line('x.font = .systemFont(ofSize: size)\n')["literal_font_sizes"], 0),
        (count_line('let c = NSColor(red: 1, green: 0, blue: 0, alpha: 1)\n')["literal_colours"], 1),
        (count_line('let c = NSColor.labelColor\n')["literal_colours"], 0),
        (count_line('s = "\\(n) document(s)"\n')["lazy_plurals"], 1),
        (count_line('s = "\\(s) and plural(s)"\n')["lazy_plurals"], 1),
        (count_line('s = "took \\(s)"; f(s)\n')["lazy_plurals"], 0),
        (count_line('NSSound.beep()\n')["beeps"], 1),
        (len(hard_failures("x", ['a.addButton(withTitle: "Delete")\n', 'a.addButton(withTitle: "Cancel")\n'])), 1),
        (len(hard_failures("x", ['a.addButton(withTitle: "Delete").hasDestructiveAction = true\n'])), 0),
        (len(hard_failures("x", ['a.addButton(withTitle: "Discard")\n', 'a.buttons.last?.hasDestructiveAction = true\n'])), 0),
        (len(hard_failures("x", ['a.addButton(withTitle: "Discard…")\n'])), 0),
        (len(hard_failures("x", ['a.addButton(withTitle: "Reset")  // design-ok: clears a draft only\n'])), 0),
        (len(hard_failures("x", ['a.addButton(withTitle: "Resettle")\n'])), 0),
        (len(hard_failures("x", ['window.tabbingMode = .preferred\n'])), 1),
        (len(hard_failures("x", ['window.tabbingMode = .disallowed\n'])), 0),
    ]
    failed = [index for index, (got, want) in enumerate(cases) if got != want]
    for index in failed:
        print(f"FAIL selftest case {index}: got {cases[index][0]}, expected {cases[index][1]}")
    print(("FAILED" if failed else "PASS") + f" design-standards selftest: {len(cases)} cases")
    return 1 if failed else 0


def main():
    if "--selftest" in sys.argv:
        return selftest()
    counts, failures, files = scan()
    if "--counts" in sys.argv:
        print(json.dumps(counts, indent=2))
        return 0
    budgets = json.loads(BUDGET.read_text(encoding="utf-8"))["budgets"]
    status = 0
    for key, rule in RULES.items():
        if key not in budgets:
            print(f"FAIL {key}: docs/design-budget.json has no budget for it")
            status = 1
            continue
        budget, count = budgets[key], counts[key]
        if count > budget:
            print(f"FAIL {key}: {count} in Sources, budget {budget} ({rule}). Remove the new use; do not raise the budget.")
            status = 1
        elif count < budget:
            print(f"PASS {key}: {count} in Sources, budget {budget} ({rule}). NOTE: lower the budget to {count}.")
        else:
            print(f"PASS {key}: {count} in Sources, at its budget ({rule})")
    for failure in failures:
        print("FAIL " + failure)
        status = 1
    if not failures:
        print("PASS destructive buttons are marked and native window tabbing is not enabled (DS-41, DS-D1)")
    print(
        ("FAILED" if status else "PASS")
        + f" design-standards: {len(RULES)} budgets and 2 hard rules over {files} files; see docs/DESIGN-STANDARDS.md"
    )
    return status


if __name__ == "__main__":
    sys.exit(main())
