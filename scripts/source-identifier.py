#!/usr/bin/env python3

import hashlib
import os
import pathlib
import stat
import subprocess
import sys
from collections.abc import Buffer
from typing import Protocol


class HashState(Protocol):
    def update(self, data: Buffer, /) -> None: ...


def git(root: pathlib.Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args])


def update_record(
    digest: HashState, path: bytes, kind: bytes, mode: int, content: bytes
) -> None:
    for value in (path, kind, f"{mode:o}".encode(), content):
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)


def dirty_identifier(root: pathlib.Path) -> str:
    records: list[tuple[bytes, bytes, int, bytes]] = []
    staged = git(root, "ls-files", "--stage", "-z", "--cached")
    for entry in (part for part in staged.split(b"\0") if part):
        metadata, path = entry.split(b"\t", 1)
        mode_text, _, stage = metadata.split(b" ", 2)
        if stage != b"0":
            raise RuntimeError("unmerged index entries cannot be assigned a source identifier")
        records.append(source_record(root, path, int(mode_text, 8), tracked=True))

    untracked = git(root, "ls-files", "-z", "--others", "--exclude-standard")
    for path in (part for part in untracked.split(b"\0") if part):
        records.append(source_record(root, path, 0, tracked=False))

    digest = hashlib.sha256()
    for path, kind, mode, content in sorted(records, key=lambda record: record[0]):
        update_record(digest, path, kind, mode, content)
    return digest.hexdigest()


def source_record(
    root: pathlib.Path, encoded_path: bytes, index_mode: int, *, tracked: bool
) -> tuple[bytes, bytes, int, bytes]:
    path = root / os.fsdecode(encoded_path)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        if tracked:
            return encoded_path, b"deleted", index_mode, b""
        raise

    mode = stat.S_IMODE(metadata.st_mode)
    if path.is_symlink():
        return encoded_path, b"symlink", mode, os.fsencode(os.readlink(path))
    if path.is_file():
        return encoded_path, b"file", mode, path.read_bytes()
    if path.is_dir() and tracked:
        commit = git(path, "rev-parse", "HEAD").strip()
        return encoded_path, b"gitlink", index_mode, commit
    raise RuntimeError(f"unsupported source path type: {os.fsdecode(encoded_path)}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: source-identifier.py REPOSITORY")
    root = pathlib.Path(sys.argv[1]).resolve()
    status = git(root, "status", "--porcelain", "--untracked-files=all")
    if not status:
        print(git(root, "rev-parse", "HEAD").decode().strip())
        return
    print(dirty_identifier(root))


if __name__ == "__main__":
    main()
