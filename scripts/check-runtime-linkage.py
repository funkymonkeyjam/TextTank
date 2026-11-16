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
    expected = {name: f"@rpath/{name}.framework/Versions/A/{name}"
                for name in ["NativeSearch", "EditorBridge"]}
    images = {name: app / f"Contents/Frameworks/{name}.framework/Versions/A/{name}"
              for name in expected}
    for name, image in images.items():
        identity = output("otool", "-D", str(image)).splitlines()[1].strip()
        if identity != expected[name]:
            raise ValueError(f"{name} has an unsupported install name: {identity}")
    native_dependencies = dependencies(images["NativeSearch"])
    if any("AppKit.framework" in item or "Scintilla.framework" in item
           or "EditorBridge.framework" in item for item in native_dependencies):
        raise ValueError("Foundation NativeSearch depends on an editor/UI framework")
    editor_dependencies = dependencies(images["EditorBridge"])
    if any("NativeSearch.framework" in item for item in editor_dependencies):
        raise ValueError("EditorBridge depends on the snapshot search engine")
    application_dependencies = [item for file in (app / "Contents/MacOS").iterdir()
                                if file.is_file() for item in dependencies(file)]
    for name, identity in expected.items():
        references = [item for item in application_dependencies if f"{name}.framework/" in item]
        if not references or any(item != identity for item in references):
            raise ValueError(f"Application does not resolve its embedded {name}: {references}")
    return expected



if __name__ == "__main__":
    try:
        verify(sys.argv[1])
    except (IndexError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"Runtime linkage rejected: {error}")
    print("PASS runtime linkage: embedded NativeSearch/EditorBridge use @rpath with separate native dependencies")
