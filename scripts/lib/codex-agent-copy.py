#!/usr/bin/env python3
"""Render/recognize physical Codex agent files without a separate ownership ledger."""
import hashlib
import json
import os
import stat
import sys
import tempfile

PREFIX = b"# the-grid managed Codex agent "


def inspect(path):
    """Only an unchanged regular file with our header is a managed copy."""
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise ValueError("not a regular file")
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("not a regular file")
        header, body = stream.read().split(b"\n", 1)
    if not header.startswith(PREFIX):
        raise ValueError("not managed")
    info = json.loads(header[len(PREFIX):])
    source = info["source"]
    if not isinstance(source, str) or not os.path.isabs(source) or any(c in source for c in "\n\r\t\0"):
        raise ValueError("invalid source")
    digest = hashlib.sha256(body).hexdigest()
    if info["sha256"] != digest:
        raise ValueError("modified copy")
    return source + "\t" + digest


def read_payload(path):
    """Keep payload bytes and permission bits from the same opened file."""
    with open(path, "rb") as stream:
        return stream.read(), stat.S_IMODE(os.fstat(stream.fileno()).st_mode)


def publish(payload, mode, destination):
    """Publish atomically without overwriting a destination, including during rollback."""
    fd, temporary = tempfile.mkstemp(prefix=".grid-agent-", dir=os.path.dirname(destination))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
        os.chmod(temporary, mode)
        # An exclusive hard link publishes the finished bytes without replacing a
        # foreign file/symlink that appeared after the shell's destination check.
        os.link(temporary, destination)
    finally:
        os.unlink(temporary)


def copy(source, destination):
    """Add provenance once; restoring a backup must use its exact original bytes."""
    source = os.path.realpath(source)
    if any(c in source for c in "\n\r\t\0"):
        raise ValueError("invalid source")
    body, mode = read_payload(source)
    info = {"source": source, "sha256": hashlib.sha256(body).hexdigest()}
    payload = PREFIX + json.dumps(info, separators=(",", ":")).encode() + b"\n" + body
    publish(payload, mode, destination)


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "inspect":
            print(inspect(sys.argv[2]))
        elif len(sys.argv) == 4 and sys.argv[1] == "copy":
            copy(sys.argv[2], sys.argv[3])
        elif len(sys.argv) == 4 and sys.argv[1] == "restore":
            payload, mode = read_payload(sys.argv[2])
            publish(payload, mode, sys.argv[3])
        else:
            sys.exit("usage: codex-agent-copy.py inspect FILE | copy SOURCE DEST | restore BACKUP DEST")
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)
