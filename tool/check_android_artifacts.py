#!/usr/bin/env python3
"""Check generated Android cores and optional APK libraries for 16 KiB support."""

import argparse
from pathlib import Path
import struct
import zipfile

PAGE_SIZE = 16384


def read_exact(stream, size, label):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError(f"{label}: truncated ELF library")
    return data


def check_elf(stream, label):
    stream.seek(0)
    ident = read_exact(stream, 16, label)
    if ident[:4] != b"\x7fELF" or ident[5] != 1:
        raise ValueError(f"{label}: expected a little-endian ELF library")
    if ident[4] == 2:
        header = ident + read_exact(stream, 48, label)
        offset = struct.unpack_from("<Q", header, 32)[0]
        size, count = struct.unpack_from("<HH", header, 54)
        program = "<IIQQQQQQ"
    elif ident[4] == 1:
        header = ident + read_exact(stream, 36, label)
        offset = struct.unpack_from("<I", header, 28)[0]
        size, count = struct.unpack_from("<HH", header, 42)
        program = "<IIIIIIII"
    else:
        raise ValueError(f"{label}: unsupported ELF class")
    program_size = struct.calcsize(program)
    if size < program_size:
        raise ValueError(f"{label}: invalid ELF program header size")
    loads = 0
    for index in range(count):
        stream.seek(offset + index * size)
        fields = struct.unpack(program, read_exact(stream, program_size, label))
        if fields[0] != 1:  # PT_LOAD
            continue
        file_offset, address, alignment = (
            (fields[2], fields[3], fields[7]) if ident[4] == 2
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
        with library.open("rb") as stream:
            check_elf(stream, str(library))
        print(f"{abi}: libwgcne.so LOAD segments support 16 KiB pages")
    if args.apk:
        with zipfile.ZipFile(args.apk) as apk:
            for abi in abis:
                apk.getinfo(f"lib/{abi}/libwgcne.so")
            libraries = [
                item for item in apk.infolist()
                if item.filename.startswith("lib/") and item.filename.endswith(".so")
            ]
            for item in libraries:
                with apk.open(item) as stream:
                    check_elf(stream, item.filename)
                    # Reading through EOF preserves ZipExtFile's CRC validation.
                    while stream.read(64 * 1024):
                        pass
                if item.compress_type == zipfile.ZIP_STORED:
                    apk.fp.seek(item.header_offset + 26)
                    name_length, extra_length = struct.unpack("<HH", apk.fp.read(4))
                    start = item.header_offset + 30 + name_length + extra_length
                    if start % PAGE_SIZE:
                        raise ValueError(
                            f"{item.filename}: uncompressed APK data "
                            "is not 16 KiB aligned"
                        )
            print(
                f"{args.apk.name}: checked ELF and ZIP alignment "
                f"for {len(libraries)} native libraries"
            )


if __name__ == "__main__":
    main()
