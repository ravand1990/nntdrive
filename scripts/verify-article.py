#!/usr/bin/env python3
"""Independently verify NNTDrive articles on a Usenet provider.

This script talks directly to the provider over NNTP/TLS, authenticates with
your credentials, fetches the article by Message-ID, decodes yEnc and prints the
SHA-256 of the shard. Compare it with the `sha256` column in PostgreSQL (or pass
--expect-sha256). It does not trust or contact the NNTDrive backend.

Usage:
  python scripts/verify-article.py --user USER --message-id ID [--expect-sha256 HEX]
  python scripts/verify-article.py --user USER --message-id-file ids.txt

The password is prompted for (or read from NNTDRIVE_NNTP_PASSWORD) and is never
written to disk or logs.

Defaults match Eweka retrieval: news.eweka.nl:563 TLS. For the posting host use
--host post.eweka.nl.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import os
import socket
import ssl
import sys
import zlib


def read_line(f) -> bytes:
    line = f.readline()
    if not line:
        raise RuntimeError("connection closed by provider")
    return line.rstrip(b"\r\n")


def read_reply(f):
    first = read_line(f)
    if len(first) < 3 or not first[:3].isdigit():
        raise RuntimeError(f"malformed NNTP reply: {first[:120]!r}")
    code = int(first[:3])
    lines = [first[4:].decode("utf-8", "replace")]
    if len(first) > 3 and first[3:4] == b"-":
        while True:
            line = read_line(f)
            if line == b".":
                break
            lines.append(line.decode("utf-8", "replace"))
    return code, lines


def command(f, text: str):
    f.write(text.encode("utf-8") + b"\r\n")
    f.flush()
    return read_reply(f)


def read_multiline(f) -> list[bytes]:
    out = []
    while True:
        line = read_line(f)
        if line == b".":
            break
        if line.startswith(b".."):
            line = line[1:]
        out.append(line)
    return out


def yenc_decode(lines: list[bytes]) -> tuple[bytes, int | None]:
    begin = None
    data = bytearray()
    declared_size = None
    crc = None
    in_data = False
    for line in lines:
        if line.startswith(b"=ybegin "):
            for part in line.split():
                if part.startswith(b"size="):
                    declared_size = int(part[5:])
            in_data = True
            continue
        if line.startswith(b"=yend "):
            for part in line.split():
                if part.startswith(b"pcrc32="):
                    crc = int(part[7:], 16)
            break
        if not in_data or line.startswith(b"=ypart"):
            continue
        i = 0
        while i < len(line):
            b = line[i]
            if b == 0x3D:  # '='
                i += 1
                if i >= len(line):
                    raise RuntimeError("truncated yEnc escape")
                data.append((line[i] - 64 - 42) & 0xFF)
            else:
                data.append((b - 42) & 0xFF)
            i += 1
    if begin is None and not data:
        raise RuntimeError("no yEnc data in article")
    if declared_size is not None and len(data) != declared_size:
        raise RuntimeError(f"yEnc size mismatch: header {declared_size}, decoded {len(data)}")
    if crc is not None and (zlib.crc32(data) & 0xFFFFFFFF) != crc:
        raise RuntimeError("yEnc CRC32 mismatch (article corrupted)")
    return bytes(data), crc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="news.eweka.nl")
    ap.add_argument("--port", type=int, default=563)
    ap.add_argument("--no-tls", action="store_true")
    ap.add_argument("--user", required=True)
    ap.add_argument("--message-id", action="append", default=[])
    ap.add_argument("--message-id-file", help="one Message-ID per line")
    ap.add_argument("--expect-sha256", help="expected SHA-256 of the decoded shard")
    ap.add_argument("--raw-out", help="write the decoded shard to this file")
    args = ap.parse_args()

    ids = list(args.message_id)
    if args.message_id_file:
        with open(args.message_id_file, encoding="utf-8") as fh:
            ids += [ln.strip() for ln in fh if ln.strip()]
    if not ids:
        ap.error("provide --message-id or --message-id-file")
    password = os.environ.get("NNTDRIVE_NNTP_PASSWORD") or getpass.getpass("NNTP password: ")

    sock = socket.create_connection((args.host, args.port), timeout=30)
    if not args.no_tls:
        ctx = ssl.create_default_context()
        sock = ctx.wrap_socket(sock, server_hostname=args.host)
    f = sock.makefile("rwb")
    try:
        code, lines = read_reply(f)
        if code not in (200, 201):
            print(f"unexpected greeting {code}: {lines}", file=sys.stderr)
            return 1
        code, _ = command(f, f"AUTHINFO USER {args.user}")
        if code == 381:
            code, lines = command(f, f"AUTHINFO PASS {password}")
        if code != 281:
            print(f"authentication failed ({code})", file=sys.stderr)
            return 2
        ok = 0
        for message_id in ids:
            mid = message_id.strip().strip("<>")
            code, _ = command(f, f"STAT <{mid}>")
            if code != 223:
                print(f"{mid}: MISSING (STAT {code})")
                continue
            code, _ = command(f, f"BODY <{mid}>")
            if code != 222:
                print(f"{mid}: BODY failed ({code})")
                continue
            body = read_multiline(f)
            data, _ = yenc_decode(body)
            digest = hashlib.sha256(data).hexdigest()
            verdict = "OK"
            if args.expect_sha256 and digest.lower() != args.expect_sha256.lower():
                verdict = "HASH MISMATCH"
            print(f"{mid}: present, {len(data)} bytes, sha256={digest} {verdict}")
            if args.raw_out:
                with open(args.raw_out, "wb") as out:
                    out.write(data)
            ok += verdict == "OK"
        command(f, "QUIT")
        return 0 if ok == len(ids) else 3
    finally:
        try:
            f.close()
            sock.close()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
