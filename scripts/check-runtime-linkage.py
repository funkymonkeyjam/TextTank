#!/usr/bin/env python3
"""Inspect built runtime dependencies without launching the application."""
from pathlib import Path
import subprocess
import sys


def output(*arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT)


def dependencies(image):
    return [line.strip().split(" (compatibility", 1)[0]
            for line in output("otool", "-L", str(image)).splitlines()[1:] if line.strip()]


def verify(app):
    app = Path(app)
    image = app / "Contents/Frameworks/NativeSearch.framework/Versions/A/NativeSearch"
    expected = "@rpath/NativeSearch.framework/Versions/A/NativeSearch"
    identity = output("otool", "-D", str(image)).splitlines()[1].strip()
    if identity != expected:
        raise ValueError(f"NativeSearch has an unsupported install name: {identity}")
    native_dependencies = dependencies(image)
    if any("AppKit.framework" in item or "Scintilla.framework" in item for item in native_dependencies):
        raise ValueError("Foundation NativeSearch depends on an editor/UI framework")
    application_dependencies = [item for file in (app / "Contents/MacOS").iterdir()
                                if file.is_file() for item in dependencies(file)]
    references = [item for item in application_dependencies if "NativeSearch.framework/" in item]
    if not references or any(item != expected for item in references):
        raise ValueError(f"Application does not resolve its embedded NativeSearch: {references}")
    return {"NativeSearch": expected}


if __name__ == "__main__":
    try:
        verify(sys.argv[1])
    except (IndexError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Runtime linkage rejected: {error}")
    print("PASS runtime linkage: embedded NativeSearch uses @rpath without UI dependencies")
