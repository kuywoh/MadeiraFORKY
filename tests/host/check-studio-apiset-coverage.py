#!/usr/bin/env python3
"""Check API-set names imported by the inspected Studio build against Wine's schema.

The contract list is from a read-only import inventory of RobloxStudioBeta.exe
version 0.742.0.7421053. Wine's get_apiset_entry() hashes and compares the
contract name only through the final hyphen-delimited version component, so
this check uses that same version-independent prefix when matching schema rows.
It verifies loader-name coverage only, not the behavior of the host APIs.
"""
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCHEMA = os.path.join(ROOT, "wine", "dlls", "apisetschema", "apisetschema.spec")

CONTRACTS = {
    "api-ms-win-core-synch-l1-2-0.dll": "kernelbase.dll",
    "api-ms-win-core-winrt-l1-1-0.dll": "combase.dll",
    "api-ms-win-core-winrt-string-l1-1-0.dll": "combase.dll",
    "api-ms-win-crt-convert-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-environment-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-filesystem-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-heap-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-locale-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-math-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-runtime-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-stdio-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-string-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-time-l1-1-0.dll": "ucrtbase.dll",
    "api-ms-win-crt-utility-l1-1-0.dll": "ucrtbase.dll",
}


def resolver_key(contract):
    """Match Wine get_apiset_entry(): ignore the final hyphen component."""
    name = contract.lower().removesuffix(".dll")
    return name.rsplit("-", 1)[0]


def main():
    with open(SCHEMA, encoding="utf-8") as source:
        rows = re.findall(
            r"^apiset\s+(\S+)\s*=\s*(\S+)", source.read(), re.MULTILINE | re.IGNORECASE
        )

    hosts_by_key = {}
    for name, host in rows:
        hosts_by_key.setdefault(resolver_key(name), set()).add(host.lower())

    ok = True
    for contract, expected_host in sorted(CONTRACTS.items()):
        hosts = hosts_by_key.get(resolver_key(contract), set())
        passed = expected_host in hosts
        print(("ok   " if passed else "FAIL ") + f"{contract} -> {expected_host}")
        ok &= passed

    print(f"{len(CONTRACTS)} Studio API-set contracts: " + ("PASS" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
