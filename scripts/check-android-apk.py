#!/usr/bin/env python3
"""Check packaged Rust libraries, not Android runtime behavior."""
import sys
from zipfile import ZipFile

with ZipFile(sys.argv[1]) as apk:
    for abi, elf_class, machine in (
        ("arm64-v8a", 2, 183), ("armeabi-v7a", 1, 40), ("x86_64", 2, 62)
    ):
        name = f"lib/{abi}/libnntdrive_ffi.so"
        data = apk.read(name)
        if (len(data) < 20 or data[:4] != b"\x7fELF" or data[4] != elf_class
                or data[5] != 1 or int.from_bytes(data[18:20], "little") != machine):
            raise SystemExit(f"Wrong ELF architecture or missing header: {name}")
        print(f"Packaged native library: {name} ({len(data)} bytes)")
