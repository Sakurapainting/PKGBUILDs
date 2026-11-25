#!/usr/bin/env python3
"""Check a GPT header read by rkdeveloptool against a Z96A image layout."""

import argparse
import json
import struct
import zlib
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_gpt(data, sector_bytes):
    header = data[sector_bytes : 2 * sector_bytes]
    require(len(header) == sector_bytes and header[:8] == b"EFI PART", "missing primary GPT")
    header_size, header_crc = struct.unpack_from("<II", header, 12)
    require(92 <= header_size <= sector_bytes, "invalid GPT header size")
    crc_data = bytearray(header[:header_size])
    struct.pack_into("<I", crc_data, 16, 0)
    require(zlib.crc32(crc_data) == header_crc, "GPT header checksum mismatch")
    own_lba, _, first_usable, last_usable = struct.unpack_from("<QQQQ", header, 24)
    table_lba, count, entry_size, table_crc = struct.unpack_from("<QIII", header, 72)
    table_start = table_lba * sector_bytes
    table_end = table_start + count * entry_size
    require(own_lba == 1 and first_usable <= last_usable, "invalid primary GPT geometry")
    require(128 <= entry_size and 0 < count and 2 * sector_bytes <= table_start,
            "invalid GPT entry geometry")
    require(table_end <= len(data), "incomplete GPT entry array, read more sectors")
    table = data[table_start:table_end]
    require(zlib.crc32(table) == table_crc, "GPT entry array checksum mismatch")
    partitions = []
    for offset in range(0, len(table), entry_size):
        entry = table[offset : offset + entry_size]
        if entry[:16] == bytes(16):
            continue
        start, end = struct.unpack_from("<QQ", entry, 32)
        label = entry[56:128].decode("utf-16-le").split("\0", 1)[0]
        require(first_usable <= start <= end <= last_usable, f"invalid GPT extent for {label}")
        partitions.append((label, start, end))
    return partitions


def check_layout(layout, partitions):
    boot, root = layout["boot"], layout["root"]
    flash_start = layout["flash_start_lba"]
    size, sector = layout["raw_bytes"], layout["sector_bytes"]
    require(flash_start == boot["start_lba"], "image does not start at BOOT")
    require(boot["start_lba"] + boot["sectors"] == root["start_lba"], "image partitions are not contiguous")
    require(size == (boot["sectors"] + root["image_sectors"]) * sector, "image size differs from layout")
    flash_end = flash_start + size // sector - 1
    targets = []
    for expected, sectors, exact_size in (
        (boot, boot["sectors"], True), (root, root["image_sectors"], False)
    ):
        matches = [part for part in partitions if part[0] == expected["partlabel"]]
        require(len(matches) == 1, f"expected one {expected['partlabel']} partition")
        label, start, end = matches[0]
        require(start == expected["start_lba"], f"unexpected {label} start LBA")
        actual_sectors = end - start + 1
        require(actual_sectors == sectors if exact_size else actual_sectors >= sectors,
                f"unexpected {label} size ({actual_sectors} sectors)")
        targets.append(matches[0])
    for part in partitions:
        label, start, end = part
        if part not in targets:
            require(end < flash_start or start > flash_end, f"flash range overlaps {label}")
    for label, start, end in targets:
        print(f"{label}: start 0x{start:X}, {end - start + 1} sectors")
    print(f"Image fits GPT range 0x{flash_start:X}–0x{flash_end:X} ({size} bytes).")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("layout", type=Path)
    parser.add_argument("gpt", type=Path, help="read with rkdeveloptool rl 0 128 gpt.bin")
    args = parser.parse_args()
    try:
        layout = json.loads(args.layout.read_text(encoding="utf-8"))
        require(layout["sector_bytes"] == 512, "unexpected sector size")
        check_layout(layout, read_gpt(args.gpt.read_bytes(), layout["sector_bytes"]))
    except (OSError, ValueError, KeyError, struct.error) as error:
        parser.exit(1, f"Layout check failed: {error}\n")


if __name__ == "__main__":
    main()
