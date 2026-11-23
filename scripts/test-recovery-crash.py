#!/usr/bin/env python3
"""Opt-in macOS Debug process-crash check. All children, documents and support files are private to this invocation."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import time
import uuid
from urllib.parse import unquote, urlsplit

from build_config import load_identity


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    command = argparse.ArgumentParser(description=__doc__)
    command.add_argument("--source", type=Path, default=Path(__file__).resolve().parent.parent)
    command.add_argument("--manifest", type=Path)
    command.add_argument("--frameworks", type=Path, help="Directory of signed embedded frameworks from this exact Debug build")
    args = command.parse_args()
    source = args.source.resolve()
    manifest = args.manifest or source / "build/artifacts/Debug/manifest.json"
    record = json.loads(manifest.read_bytes())
    if record["configuration"] != "Debug":
        raise RuntimeError("Run this check with a verified Debug validation build.")
    for name, target in record["inputs"].items():
        if sha((source / name).read_bytes()) != target["sha256"]:
            raise RuntimeError("Build input differs: " + name)
    roots = []
    runtime_roots = []
    images = {}
    for name, producer in record["images"].items():
        binary = Path(producer["produced"]).resolve()
        if sha(binary.read_bytes()) != producer["produced_sha256"]:
            raise RuntimeError("Produced framework differs: " + name)
        roots.append(binary.parents[3])
        signed = ((args.frameworks / (name + ".framework") / name) if args.frameworks else Path(producer["embedded"])).resolve()
        if not signed.is_file() or sha(signed.read_bytes()) != producer["embedded_sha256"]:
            raise RuntimeError("Signed embedded framework missing or mismatched: " + name)
        subprocess.run(["codesign", "--verify", "--strict", str(signed.parents[2])], check=True)
        runtime_roots.append(signed.parents[3])
        images[name] = signed
    proc_path = ctypes.CDLL("/usr/lib/libproc.dylib").proc_pidpath
    proc_path.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc_path.restype = ctypes.c_int
    original = "recovery café\r\n".encode()
    expected = original + "  Δ🧪\0tail".encode()
    token = str(uuid.uuid4())
    with tempfile.TemporaryDirectory(prefix="TextTank-crash-", dir="/private/tmp") as raw:
        folder = Path(raw)
        (folder / "owner-token").write_text(token)
        support = folder / "support"
        support.mkdir()
        (folder / "home").mkdir()
        path = folder / "original.txt"
        path.write_bytes(original)
        executable = folder / ("TextTankCrashFixture-" + token)
        info = plistlib.loads((source / "Resources/Info.plist").read_bytes())
        metadata = {"NSPrincipalClass": "RecoveryCrashFixtureApplication", "CFBundleIdentifier": "test.texttank.crash." + token.lower(),
                    "CFBundleName": "TextTank Recovery Fixture", "CFBundleExecutable": executable.name,
                    "CFBundleDocumentTypes": info["CFBundleDocumentTypes"]}
        plist = folder / "fixture.plist"
        plist.write_bytes(plistlib.dumps(metadata))
        flags = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-strict-concurrency=complete",
                 "-warnings-as-errors", "-package-name", "TextTank", "-sdk", record["toolchain"]["sdk"],
                 "-target", "arm64-apple-macos" + load_identity()["deploymentTarget"]]
        for directory in dict.fromkeys(roots):
            flags += ["-F", str(directory)]
        for directory in dict.fromkeys(runtime_roots):
            flags += ["-Xlinker", "-rpath", "-Xlinker", str(directory)]
        for framework in [*images, "AppKit", "EventKit"]:
            flags += ["-framework", framework]
        client = Path(__file__).resolve().parent.parent / "Tests/RecoveryCrashAppChecks.swift"
        subprocess.run(flags + [str(client), "-lc++", "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                "-Xlinker", "__info_plist", "-Xlinker", str(plist), "-o", str(executable)], check=True)
        env = dict(os.environ, CFFIXED_USER_HOME=str(folder / "home"), TEXTTANK_SUPPORT_DIRECTORY=str(support),
                   TEXTTANK_REPO_ROOT=str(source), NSUnbufferedIO="YES")
        def verify_pid(process):
            buf = ctypes.create_string_buffer(4096)
            if process.poll() is not None or not proc_path(process.pid, buf, len(buf)) or Path(os.fsdecode(buf.value)).resolve() != executable:
                raise RuntimeError("Refusing to signal an unidentified or exited child")
        def snapshot(process, mode, phase, deadline):
            receipt = folder / (mode + "-" + phase + ".json")
            while not receipt.exists():
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError(f"{mode} child {process.pid} never reached {phase} (exit {process.poll()})")
                time.sleep(0.025)
            value = json.loads(receipt.read_bytes())
            if (value["token"], value["pid"], value["executable"], str(Path(value["root"]).resolve()), value["prohibited"]) != (token, process.pid, str(executable), str(support), True):
                raise RuntimeError("Child receipt identity mismatch " + repr((value["token"], value["pid"], value["executable"], value["root"], value["prohibited"], str(support))))
            loaded = {Path(image).name: Path(image).resolve() for image in value["images"]}
            if loaded != images:
                raise RuntimeError("Child loaded unexpected framework identities")
            print(json.dumps(value, sort_keys=True), flush=True)
            return value
        for mode in ["early", "empty", "edit", "later", "recover"]:
            deadline = time.monotonic() + 22
            child_env = dict(env, TEXTTANK_CRASH_CHECK_PHASE=mode, TEXTTANK_CRASH_CHECK_DIRECTORY=str(folder),
                             TEXTTANK_CRASH_CHECK_TOKEN=token)
            process = subprocess.Popen([executable], env=child_env, cwd=folder)
            try:
                snapshot(process, mode, "ready", deadline)
                if mode == "early":
                    dirty = snapshot(process, mode, "unpublished", deadline)
                    if not dirty["dirty"] or dirty["digest"] != sha(expected) or list((support / "Recovery").glob("*.json")) or list((support / "Recovery").glob("*.utf8")):
                        raise RuntimeError("The pre-timer control published a recovery file or has incorrect editor bytes")
                    verify_pid(process)
                    process.kill()
                    if process.wait(timeout=5) != -signal.SIGKILL:
                        raise RuntimeError("Pre-publication editing child did not exit through the fixture signal")
                elif mode == "empty":
                    empty = snapshot(process, mode, "empty", deadline)
                    if empty["reviewed"] or process.wait(timeout=6) != 0:
                        raise RuntimeError("Cold startup offered an unpublished draft")
                elif mode == "edit":
                    edited = snapshot(process, mode, "edited", deadline)
                    done = snapshot(process, mode, "published", deadline)
                    if not done["dirty"] or done["digest"] != sha(expected):
                        raise RuntimeError("Editing child did not publish the expected dirty bytes")
                    metadata_file, = support.rglob(done["id"] + ".json")
                    header = json.loads(metadata_file.read_bytes())
                    body = metadata_file.with_name(done["id"] + "." + header["generation"] + ".utf8")
                    durable = (metadata_file.read_bytes(), body.read_bytes())
                    origin = urlsplit(header["originalURL"])
                    if origin.scheme != "file" or Path(unquote(origin.path)).resolve() != path:
                        raise RuntimeError("Recovery no longer identifies its original disk file")
                    if header["schemaVersion"] != 2 or header["sha256"] != sha(expected) or durable[1] != expected:
                        raise RuntimeError("Published recovery bytes failed independent validation")
                    print(json.dumps({"durable_header": sha(durable[0]), "payload": sha(durable[1]),
                                      "timer_observed_seconds": done["uptime"] - edited["uptime"],
                                      "original": sha(original), "revision": header["revision"]}), flush=True)
                    verify_pid(process)
                    process.kill()
                    if process.wait(timeout=5) != -signal.SIGKILL:
                        raise RuntimeError("Editing child did not exit through the expected fixture signal")
                    print("Verified owned editing child exited via SIGKILL after durable publication", flush=True)
                else:
                    choice = snapshot(process, mode, "review", deadline)
                    if choice["button"] != ("Later" if mode == "later" else "Recover"):
                        raise RuntimeError("Wrong recovery choice")
                    result = snapshot(process, mode, "kept" if mode == "later" else "restored", deadline)
                    if process.wait(timeout=6) != 0:
                        raise RuntimeError("Review child failed to terminate normally")
                    if mode == "later" and (metadata_file.read_bytes(), body.read_bytes()) != durable:
                        raise RuntimeError("Later changed the published draft")
                    if mode == "recover" and (not result["dirty"] or not result["untitled"] or result["digest"] != sha(expected) or result["id"] != done["id"] or metadata_file.exists() or body.exists()):
                        raise RuntimeError("Recovered editor did not match published bytes")
                if path.read_bytes() != original:
                    raise RuntimeError("Original file bytes changed")
            finally:
                if process.poll() is None:
                    verify_pid(process)
                    process.kill()
                    process.wait(timeout=5)
    print("PASS: unpublished crash, clean startup, native edit, timed v2 publication, verified child crash, Later, restored dirty draft, original file and snapshot cleanup")


if __name__ == "__main__":
    main()
