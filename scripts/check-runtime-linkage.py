#!/usr/bin/env python3
"""Inspect the complete selected application dependency closure without launching it."""
from runtime_linkage import verify
import subprocess
import sys

if __name__ == '__main__':
    try:
        result = verify(sys.argv[1])
    except (IndexError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Runtime linkage rejected: {error}')
    print(f'PASS runtime linkage: {len(result["images"])} classified arm64 code images; complete embedded dependency/runpath closure')
