#!/usr/bin/env python3
"""Check generated Android cores and optional APK libraries for 16 KiB support."""

import argparse
from pathlib import Path
import struct
import zipfile

PAGE_SIZE = 16384


def check_elf(data, label):
    if data[:4] != b"\x7fELF" or data[5] != 1:
        raise ValueError(f"{label}: expected a little-endian ELF library")
    if data[4] == 2:
        offset = struct.unpack_from("<Q", data, 32)[0]
        size, count = struct.unpack_from("<HH", data, 54)
        program = "<IIQQQQQQ"
    elif data[4] == 1:
        offset = struct.unpack_from("<I", data, 28)[0]
        size, count = struct.unpack_from("<HH", data, 42)
        program = "<IIIIIIII"
    else:
        raise ValueError(f"{label}: unsupported ELF class")
    loads = 0
    for index in range(count):
        fields = struct.unpack_from(program, data, offset + index * size)
        if fields[0] != 1:  # PT_LOAD
            continue
        file_offset, address, alignment = (
            (fields[2], fields[3], fields[7]) if data[4] == 2
            else (fields[1], fields[2], fields[7])
        )
        if alignment < PAGE_SIZE or file_offset % PAGE_SIZE != address % PAGE_SIZE:
            raise ValueError(f"{label}: LOAD segment is not 16 KiB aligned")
        loads += 1
    if not loads:
        raise ValueError(f"{label}: no LOAD segments")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jni-libs", type=Path, required=True)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--abis", default="arm64-v8a,x86_64")
    args = parser.parse_args()
    abis = args.abis.split(",")
    for abi in abis:
        library = args.jni_libs / abi / "libwgcne.so"
        check_elf(library.read_bytes(), str(library))
        print(f"{abi}: libwgcne.so LOAD segments support 16 KiB pages")
    if args.apk:
        with zipfile.ZipFile(args.apk) as apk:
            for abi in abis:
                apk.getinfo(f"lib/{abi}/libwgcne.so")
            libraries = [item for item in apk.infolist()
                         if item.filename.startswith("lib/") and item.filename.endswith(".so")]
            for item in libraries:
                check_elf(apk.read(item), item.filename)
                if item.compress_type == zipfile.ZIP_STORED:
                    apk.fp.seek(item.header_offset + 26)
                    name_length, extra_length = struct.unpack("<HH", apk.fp.read(4))
                    start = item.header_offset + 30 + name_length + extra_length
                    if start % PAGE_SIZE:
                        raise ValueError(f"{item.filename}: uncompressed APK data is not 16 KiB aligned")
            print(f"{args.apk.name}: checked ELF and ZIP alignment for {len(libraries)} native libraries")


if __name__ == "__main__":
    main()
