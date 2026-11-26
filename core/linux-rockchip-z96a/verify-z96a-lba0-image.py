#!/usr/bin/env python3
"""Verify a full-disk Z96A image, both GPT copies, firmware prefix and payload extents."""

import argparse
import struct
import uuid
import zlib
from pathlib import Path

SECTOR = 512
TOTAL_SECTORS = 61071360
TABLE_ENTRIES = 128
ENTRY_SIZE = 128
TABLE_BYTES = TABLE_ENTRIES * ENTRY_SIZE
TYPE_LINUX = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
PREFIX_SECTORS = 190464
ROOT_IMAGE_SECTORS = 7340032
PARTITIONS = [
    ("security", 8192, 16383),
    ("uboot", 16384, 24575),
    ("trust", 24576, 32767),
    ("misc", 32768, 40959),
    ("proinfo", 40960, 49151),
    ("dtbo", 49152, 57343),
    ("vbmeta", 57344, 59391),
    ("boot", 59392, 190463),
    ("BOOT", 190464, 714751),
    ("ROOT", 714752, 61071326),
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_exact(file, offset, length):
    file.seek(offset)
    data = file.read(length)
    require(len(data) == length, f"short read at byte offset {offset}")
    return data


def verify_header(data, expected_lba, expected_backup, expected_table_lba):
    require(len(data) == SECTOR and data[:8] == b"EFI PART", "missing GPT header")
    revision, header_size, header_crc, reserved = struct.unpack_from("<IIII", data, 8)
    require(revision == 0x00010000 and 92 <= header_size <= SECTOR and reserved == 0,
            "invalid GPT header fields")
    check = bytearray(data[:header_size])
    struct.pack_into("<I", check, 16, 0)
    require((zlib.crc32(check) & 0xFFFFFFFF) == header_crc, "GPT header CRC mismatch")
    current, backup, first, last = struct.unpack_from("<QQQQ", data, 24)
    disk_guid = uuid.UUID(bytes_le=data[56:72])
    table_lba, count, entry_size, table_crc = struct.unpack_from("<QIII", data, 72)
    require((current, backup, first, last) == (expected_lba, expected_backup, 34, TOTAL_SECTORS - 34),
            f"unexpected GPT geometry in header at LBA {expected_lba}")
    require((table_lba, count, entry_size) == (expected_table_lba, TABLE_ENTRIES, ENTRY_SIZE),
            "unexpected GPT entry array geometry")
    return disk_guid, table_lba, table_crc


def verify_table(table):
    entries = []
    for index in range(TABLE_ENTRIES):
        entry = table[index * ENTRY_SIZE : (index + 1) * ENTRY_SIZE]
        if entry[:16] == bytes(16):
            continue
        require(entry[:16] == TYPE_LINUX.bytes_le, "unexpected partition type GUID")
        first, last, _attrs = struct.unpack_from("<QQQ", entry, 32)
        name = entry[56:128].decode("utf-16-le").split("\0", 1)[0]
        entries.append((name, first, last))
    require(entries == PARTITIONS, f"GPT partition table differs from Z96A layout: {entries!r}")
    return entries


def compare_regions(image, reference, image_offset, reference_offset, length, label):
    with image.open("rb") as left, reference.open("rb") as right:
        left.seek(image_offset)
        right.seek(reference_offset)
        remaining = length
        while remaining:
            amount = min(8 * 1024 * 1024, remaining)
            a, b = left.read(amount), right.read(amount)
            require(len(a) == amount and len(b) == amount, f"short read while checking {label}")
            require(a == b, f"byte mismatch in {label}")
            remaining -= amount
    print(f"PASS {label}: {length} bytes match")


def require_zero_region(image, start, length, label):
    with image.open("rb") as stream:
        stream.seek(start)
        remaining = length
        while remaining:
            data = stream.read(min(8 * 1024 * 1024, remaining))
            require(data and not any(data), f"expected sanitized zeroed {label}")
            remaining -= len(data)
    print(f"PASS sanitized {label}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="full-disk raw image or virtual-flash readback")
    parser.add_argument("--prefix", type=Path, required=True, help="decompressed 190464-LBA firmware prefix")
    parser.add_argument("--boot", type=Path, required=True, help="standalone BOOT partition image")
    parser.add_argument("--root", type=Path, required=True, help="standalone ROOT partition image")
    args = parser.parse_args()

    require(args.image.stat().st_size == TOTAL_SECTORS * SECTOR, "full image has the wrong eMMC capacity")
    require(args.prefix.stat().st_size == PREFIX_SECTORS * SECTOR, "firmware prefix has the wrong size")
    require(args.boot.stat().st_size == (714752 - 190464) * SECTOR, "BOOT image has the wrong size")
    require(args.root.stat().st_size == ROOT_IMAGE_SECTORS * SECTOR,
            "ROOT filesystem image has the wrong size")

    with args.image.open("rb") as image:
        mbr = read_exact(image, 0, SECTOR)
        require(mbr[510:512] == b"\x55\xaa", "missing MBR signature")
        protective = mbr[446:462]
        _boot, _chs1, ptype, _chs2, start, count = struct.unpack("<B3sB3sII", protective)
        require(ptype == 0xEE and start == 1 and count == TOTAL_SECTORS - 1,
                "invalid protective MBR")

        primary_data = read_exact(image, SECTOR, SECTOR)
        primary_guid, primary_table_lba, primary_crc = verify_header(
            primary_data, 1, TOTAL_SECTORS - 1, 2
        )
        primary_table = read_exact(image, primary_table_lba * SECTOR, TABLE_BYTES)
        require((zlib.crc32(primary_table) & 0xFFFFFFFF) == primary_crc,
                "primary GPT partition array CRC mismatch")

        backup_table_lba = TOTAL_SECTORS - 1 - TABLE_BYTES // SECTOR
        backup_data = read_exact(image, (TOTAL_SECTORS - 1) * SECTOR, SECTOR)
        backup_guid, actual_backup_table_lba, backup_crc = verify_header(
            backup_data, TOTAL_SECTORS - 1, 1, backup_table_lba
        )
        backup_table = read_exact(image, actual_backup_table_lba * SECTOR, TABLE_BYTES)
        require(primary_guid == backup_guid, "primary/backup GPT disk GUID mismatch")
        require(primary_table == backup_table, "primary/backup GPT entries differ")
        require(primary_crc == backup_crc, "primary/backup GPT CRC differs")
        entries = verify_table(primary_table)

    for name, first, last in entries:
        if name in {"security", "trust", "misc", "proinfo", "dtbo", "vbmeta", "boot"}:
            require_zero_region(args.image, first * SECTOR, (last - first + 1) * SECTOR, name)

    # The image replaces LBA0..33 with its generated GPT, so compare firmware and
    # intentionally blank areas from LBA34 through the end of the source prefix.
    compare_regions(args.image, args.prefix, 34 * SECTOR, 34 * SECTOR,
                    (PREFIX_SECTORS - 34) * SECTOR, "firmware prefix from LBA34")
    compare_regions(args.image, args.boot, 190464 * SECTOR, 0, args.boot.stat().st_size, "BOOT payload")
    compare_regions(args.image, args.root, 714752 * SECTOR, 0, args.root.stat().st_size, "ROOT payload")
    print(f"PASS full LBA0 image: {TOTAL_SECTORS} sectors, {TOTAL_SECTORS * SECTOR} bytes")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, struct.error) as error:
        raise SystemExit(f"Full-disk image verification failed: {error}") from error
