#!/usr/bin/env python3
"""Regression fixtures for bounded Android ELF and APK validation."""

from contextlib import redirect_stdout
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

import check_android_artifacts as checker


def make_elf(bits=64, *, segments=None, padding=0, tail_size=0):
    if segments is None:
        segments = [(1, 0, 0, checker.PAGE_SIZE)]
    header = bytearray(64 if bits == 64 else 52)
    header[:7] = b"\x7fELF" + bytes((2 if bits == 64 else 1, 1, 1))
    program = "<IIQQQQQQ" if bits == 64 else "<IIIIIIII"
    stride = struct.calcsize(program) + padding
    struct.pack_into("<Q" if bits == 64 else "<I", header,
                     32 if bits == 64 else 28, len(header))
    struct.pack_into("<HH", header, 54 if bits == 64 else 42,
                     stride, len(segments))
    entries = []
    for kind, offset, address, alignment in segments:
        fields = ((kind, 0, offset, address, 0, 0, 0, alignment) if bits == 64
                  else (kind, offset, address, 0, 0, 0, 0, alignment))
        entries.append(struct.pack(program, *fields) + b"\0" * padding)
    return bytes(header) + b"".join(entries) + b"\xa5" * tail_size


class HeaderReader(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.bytes_read = 0

    def read(self, size=-1):
        if not 0 <= size <= 64:
            raise AssertionError(f"unbounded ELF read: {size}")
        data = super().read(size)
        self.bytes_read += len(data)
        return data


class ElfTests(unittest.TestCase):
    def test_reads_only_headers_for_both_classes_and_padded_entries(self):
        for bits in (32, 64):
            for padding in (0, 8):
                with self.subTest(bits=bits, padding=padding):
                    stream = HeaderReader(make_elf(
                        bits, segments=[(1, 4096, 20480, 32768)] * 10,
                        padding=padding, tail_size=1024 * 1024,
                    ))
                    checker.check_elf(stream, "fixture")
                    self.assertEqual(stream.bytes_read, 624 if bits == 64 else 372)

    def test_rejects_small_alignment_and_incongruent_addresses(self):
        for bits in (32, 64):
            for segment in ((1, 0, 0, 8192), (1, 1, 0, checker.PAGE_SIZE)):
                with self.subTest(bits=bits, segment=segment):
                    with self.assertRaisesRegex(ValueError, "LOAD segment"):
                        checker.check_elf(io.BytesIO(make_elf(
                            bits, segments=[segment],
                        )), "fixture")

    def test_requires_load_segments(self):
        for bits in (32, 64):
            for segments in ([], [(2, 0, 0, checker.PAGE_SIZE)]):
                with self.subTest(bits=bits, segments=segments):
                    with self.assertRaisesRegex(ValueError, "no LOAD segments"):
                        checker.check_elf(io.BytesIO(make_elf(
                            bits, segments=segments,
                        )), "fixture")

    def test_rejects_truncated_ident_header_and_program_headers(self):
        for bits in (32, 64):
            data = make_elf(bits)
            header_size = 64 if bits == 64 else 52
            for length in (0, 4, 15, 16, header_size - 1, len(data) - 1):
                with self.subTest(bits=bits, length=length):
                    with self.assertRaisesRegex(ValueError, "truncated ELF"):
                        checker.check_elf(io.BytesIO(data[:length]), "fixture")
            beyond_eof = bytearray(data)
            struct.pack_into("<Q" if bits == 64 else "<I", beyond_eof,
                             32 if bits == 64 else 28, 1024 * 1024)
            with self.assertRaisesRegex(ValueError, "truncated ELF"):
                checker.check_elf(io.BytesIO(beyond_eof), "fixture")

    def test_rejects_short_program_header_stride(self):
        for bits in (32, 64):
            data = bytearray(make_elf(bits))
            struct.pack_into("<H", data, 54 if bits == 64 else 42, 1)
            with self.assertRaisesRegex(ValueError, "program header size"):
                checker.check_elf(io.BytesIO(data), "fixture")

    def test_rejects_magic_byte_order_and_class(self):
        for offset, value, message in (
            (0, 0, "little-endian ELF"),
            (5, 2, "little-endian ELF"),
            (4, 3, "unsupported ELF class"),
        ):
            data = bytearray(make_elf())
            data[offset] = value
            with self.assertRaisesRegex(ValueError, message):
                checker.check_elf(io.BytesIO(data), "fixture")


class ApkTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.jni = self.root / "jniLibs"
        self.library = self.jni / "arm64-v8a" / "libwgcne.so"
        self.library.parent.mkdir(parents=True)
        self.apk = self.root / "fixture.apk"
        self.member = "lib/arm64-v8a/libwgcne.so"

    def write_apk(self, data, compression, *, aligned=True):
        self.library.write_bytes(data)
        info = zipfile.ZipInfo(self.member)
        if aligned and compression == zipfile.ZIP_STORED:
            padding = -(30 + len(self.member.encode())) % checker.PAGE_SIZE
            if padding < 4:
                padding += checker.PAGE_SIZE
            info.extra = struct.pack("<HH", 0xFFFF, padding - 4) + b"\0" * (padding - 4)
        with zipfile.ZipFile(self.apk, "w") as apk:
            apk.writestr(info, data, compress_type=compression)

    def run_checker(self):
        arguments = [
            "check_android_artifacts.py", "--jni-libs", str(self.jni),
            "--apk", str(self.apk), "--abis", "arm64-v8a",
        ]
        output = io.StringIO()
        with mock.patch.object(sys, "argv", arguments), redirect_stdout(output):
            checker.main()
        return output.getvalue()

    def test_stored_and_deflated_elf32_and_elf64_use_bounded_reads(self):
        original_read = zipfile.ZipExtFile.read
        for bits in (32, 64):
            for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                with self.subTest(bits=bits, compression=compression):
                    data = make_elf(bits, tail_size=3 * 64 * 1024)
                    self.write_apk(data, compression)
                    reads = []

                    def bounded_read(stream, size=-1):
                        self.assertGreaterEqual(size, 0)
                        self.assertLessEqual(size, 64 * 1024)
                        result = original_read(stream, size)
                        reads.append(len(result))
                        return result

                    with (
                        mock.patch.object(
                            Path, "read_bytes", side_effect=AssertionError,
                        ),
                        mock.patch.object(
                            zipfile.ZipFile, "read", side_effect=AssertionError,
                        ),
                        mock.patch.object(zipfile.ZipExtFile, "read", bounded_read),
                    ):
                        output = self.run_checker()
                    self.assertIn("checked ELF and ZIP alignment for 1", output)
                    self.assertEqual(sum(reads), len(data))
                    self.assertEqual(
                        reads[-1], 0, "the member must be drained through EOF",
                    )

    def test_rejects_invalid_elf_in_stored_and_deflated_members(self):
        for bits in (32, 64):
            cases = [
                (make_elf(bits, segments=[(1, 0, 0, 8192)]), "LOAD segment"),
                (make_elf(bits, segments=[(1, 1, 0, 16384)]), "LOAD segment"),
                (make_elf(bits, segments=[]), "no LOAD segments"),
                (make_elf(bits)[:-1], "truncated ELF"),
            ]
            for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                for data, message in cases:
                    with self.subTest(bits=bits, compression=compression,
                                      message=message):
                        self.write_apk(data, compression)
                        self.library.write_bytes(make_elf(bits))
                        with self.assertRaisesRegex(ValueError, message):
                            self.run_checker()

    def test_stored_member_requires_zip_alignment(self):
        self.write_apk(make_elf(), zipfile.ZIP_STORED, aligned=False)
        with self.assertRaisesRegex(ValueError, "uncompressed APK data"):
            self.run_checker()

    def test_crc_covers_tail_before_checking_zip_alignment(self):
        for bits in (32, 64):
            for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                with self.subTest(bits=bits, compression=compression):
                    data = make_elf(bits, tail_size=3 * 64 * 1024)
                    self.write_apk(data, compression, aligned=False)
                    # Keep deflate bytes valid across zlib versions. A wrong
                    # expected checksum must still be detected only at EOF.
                    with zipfile.ZipFile(self.apk) as apk:
                        info = apk.getinfo(self.member)
                        checksum = struct.pack("<I", info.CRC ^ 1)
                        checksum_offsets = (info.header_offset + 14, apk.start_dir + 16)
                    with self.apk.open("r+b") as archive:
                        for offset in checksum_offsets:
                            archive.seek(offset)
                            archive.write(checksum)
                    with self.assertRaisesRegex(zipfile.BadZipFile, "Bad CRC-32"):
                        self.run_checker()

    def test_checks_additional_native_libraries(self):
        self.write_apk(make_elf(), zipfile.ZIP_DEFLATED)
        with zipfile.ZipFile(self.apk, "a") as apk:
            apk.writestr(
                "lib/arm64-v8a/libextra.so", make_elf(segments=[(1, 0, 0, 8192)]),
                compress_type=zipfile.ZIP_DEFLATED,
            )
        with self.assertRaisesRegex(ValueError, "libextra.so: LOAD segment"):
            self.run_checker()


if __name__ == "__main__":
    unittest.main()
