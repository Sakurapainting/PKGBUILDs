#!/usr/bin/env python3
"""Write a Z96A-compatible primary/backup GPT to a pre-sized raw disk image."""

import argparse
import os
import struct
import uuid
import zlib
from pathlib import Path

SECTOR = 512
ENTRY_COUNT = 128
ENTRY_SIZE = 128
TABLE_BYTES = ENTRY_COUNT * ENTRY_SIZE
TYPE_LINUX = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
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


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def make_table() -> bytes:
    table = bytearray(TABLE_BYTES)
    for index, (name, first, last) in enumerate(PARTITIONS):
        entry = bytearray(ENTRY_SIZE)
        entry[0:16] = TYPE_LINUX.bytes_le
        entry[16:32] = uuid.uuid4().bytes_le
        struct.pack_into("<QQQ", entry, 32, first, last, 0)
        encoded_name = name.encode("utf-16-le")
        if len(encoded_name) > 72:
            raise ValueError(f"GPT partition name is too long: {name}")
        entry[56 : 56 + len(encoded_name)] = encoded_name
        start = index * ENTRY_SIZE
        table[start : start + ENTRY_SIZE] = entry
    return bytes(table)


def make_header(*, current: int, backup: int, first_usable: int,
                last_usable: int, disk_guid: uuid.UUID,
                entries_lba: int, table_crc: int) -> bytes:
    header = bytearray(SECTOR)
    struct.pack_into(
        "<8sIIIIQQQQ16sQIII",
        header,
        0,
        b"EFI PART",
        0x00010000,
        92,
        0,
        0,
        current,
        backup,
        first_usable,
        last_usable,
        disk_guid.bytes_le,
        entries_lba,
        ENTRY_COUNT,
        ENTRY_SIZE,
        table_crc,
    )
    struct.pack_into("<I", header, 16, crc32(header[:92]))
    return bytes(header)


def write_at(fd: int, lba: int, data: bytes) -> None:
    os.pwrite(fd, data, lba * SECTOR)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path, help="already-sized sparse raw disk image")
    parser.add_argument("--sectors", type=int, default=61071360)
    args = parser.parse_args()

    expected_bytes = args.sectors * SECTOR
    if args.sectors <= 0 or args.image.stat().st_size != expected_bytes:
        raise SystemExit(f"image must be exactly {expected_bytes} bytes ({args.sectors} sectors)")
    if args.sectors <= PARTITIONS[-1][2] + 33:
        raise SystemExit("disk is too small for the Z96A GPT layout")

    table = make_table()
    table_sectors = TABLE_BYTES // SECTOR
    first_usable = 2 + table_sectors
    last_usable = args.sectors - table_sectors - 2
    if PARTITIONS[-1][2] > last_usable:
        raise SystemExit("ROOT partition would overlap the backup GPT")

    disk_guid = uuid.uuid4()
    table_crc = crc32(table)
    primary_header = make_header(
        current=1,
        backup=args.sectors - 1,
        first_usable=first_usable,
        last_usable=last_usable,
        disk_guid=disk_guid,
        entries_lba=2,
        table_crc=table_crc,
    )
    backup_table_lba = args.sectors - 1 - table_sectors
    backup_header = make_header(
        current=args.sectors - 1,
        backup=1,
        first_usable=first_usable,
        last_usable=last_usable,
        disk_guid=disk_guid,
        entries_lba=backup_table_lba,
        table_crc=table_crc,
    )

    mbr = bytearray(SECTOR)
    # One protective 0xEE partition spanning the device (saturated at uint32).
    mbr[446:462] = struct.pack(
        "<B3sB3sII", 0, b"\0\x02\0", 0xEE, b"\xff\xff\xff",
        1, min(args.sectors - 1, 0xFFFFFFFF)
    )
    mbr[510:512] = b"\x55\xaa"

    fd = os.open(args.image, os.O_RDWR)
    try:
        write_at(fd, 0, bytes(mbr))
        write_at(fd, 1, primary_header)
        write_at(fd, 2, table)
        write_at(fd, backup_table_lba, table)
        write_at(fd, args.sectors - 1, backup_header)
        os.fsync(fd)
    finally:
        os.close(fd)

    print(f"Wrote Z96A GPT: {args.sectors} sectors, {len(PARTITIONS)} partitions, disk GUID {disk_guid}")


if __name__ == "__main__":
    main()
