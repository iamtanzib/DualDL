#!/usr/bin/env python3
"""Unzips a finished download into one main folder.

Handles the two ways big folders arrive in pieces:

* Google Drive "Download all": name-20260101T120000Z-1-001.zip, -002.zip, ...
  Every piece is a complete zip holding part of the same folder, so each one is
  extracted into the same place as it finishes and the folder fills up.
* Split archives: name.zip.001, name.zip.002, ... (one zip cut into pieces).
  Nothing can be extracted until every piece is there; until then this reports
  "waiting" and the next finished piece tries again.

Entries are never written outside the target folder, existing files with the
same size are skipped, and different files with the same name are kept side by
side. Prints one JSON object per line.

    python3 unzip.py <file.zip | file.zip.001>
"""
import json
import os
import re
import shutil
import sys
import time
import zipfile

DRIVE_PART = re.compile(r"-\d{8}T\d{6}Z-\d+-\d{3}$")       # Google Drive piece suffix
SPLIT_PART = re.compile(r"^(?P<base>.+\.zip)\.(?P<n>\d{3})$", re.I)
JUNK = ("__MACOSX/", ".DS_Store")


def emit(event, **data):
    data["event"] = event
    sys.stdout.write(json.dumps(data) + "\n")
    sys.stdout.flush()


class Joined:
    """Read-only, seekable view of several files one after another (for split zips)."""

    def __init__(self, paths):
        self.files = [open(p, "rb") for p in paths]
        self.sizes = [os.path.getsize(p) for p in paths]
        self.total = sum(self.sizes)
        self.pos = 0

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        base = {0: 0, 1: self.pos, 2: self.total}[whence]
        self.pos = max(0, base + offset)
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.total - self.pos
        out = []
        while n > 0 and self.pos < self.total:
            start = 0
            for f, size in zip(self.files, self.sizes):
                if self.pos < start + size:
                    f.seek(self.pos - start)
                    chunk = f.read(min(n, start + size - self.pos))
                    out.append(chunk)
                    self.pos += len(chunk)
                    n -= len(chunk)
                    break
                start += size
        return b"".join(out)

    def close(self):
        for f in self.files:
            f.close()


def open_archive(path):
    """Returns (ZipFile, group name) or raises LookupError while split pieces are missing."""
    folder, name = os.path.split(path)
    m = SPLIT_PART.match(name)
    if m:
        base = m.group("base")
        pieces = sorted(p for p in os.listdir(folder) if SPLIT_PART.match(p)
                        and SPLIT_PART.match(p).group("base") == base)
        numbers = [int(SPLIT_PART.match(p).group("n")) for p in pieces]
        if numbers != list(range(1, len(numbers) + 1)):
            raise LookupError("piece %d is missing" % next(i for i in range(1, 1000) if i not in numbers))
        try:
            return zipfile.ZipFile(Joined([os.path.join(folder, p) for p in pieces])), base[:-4]
        except zipfile.BadZipFile:
            raise LookupError("more pieces are still coming")    # no end record yet
    stem = name[:-4] if name.lower().endswith(".zip") else name
    return zipfile.ZipFile(path), DRIVE_PART.sub("", stem).strip() or stem


def safe_parts(member):
    """Path pieces of a zip entry, or None if it tries to leave the target folder."""
    parts = [p for p in member.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or ".." in parts or member.startswith("/") or re.match(r"^[A-Za-z]:", member):
        return None
    return parts


def free_name(path):
    base, ext = os.path.splitext(path)
    n = 1
    while os.path.exists(path):
        path = "%s (%d)%s" % (base, n, ext)
        n += 1
    return path


def extract(path):
    try:
        z, group = open_archive(path)
    except LookupError as e:
        emit("waiting", message="Split archive: %s" % e)
        return
    with z:
        infos = [i for i in z.infolist()
                 if not i.filename.startswith(JUNK[0]) and not i.filename.endswith(JUNK[1])]
        if any(i.flag_bits & 0x1 for i in infos):
            sys.exit("This zip has a password. Click Open (or double-click it in Finder) and type the password.")
        tops = {safe_parts(i.filename)[0] for i in infos if safe_parts(i.filename)}
        single_root = len(tops) == 1 and all(len(safe_parts(i.filename) or []) > 1 or i.is_dir()
                                             for i in infos)
        folder = os.path.dirname(path)
        # Zips that already hold one folder (Drive does this) merge into it;
        # loose files get a folder named after the download.
        dest = folder if single_root else os.path.join(folder, group)
        main = os.path.join(folder, tops.pop()) if single_root else dest

        total = sum(i.file_size for i in infos)
        free = shutil.disk_usage(folder).free
        if total > free:
            sys.exit("Not enough disk space: needs %.1f GB, %.1f GB free."
                     % (total / 1e9, free / 1e9))
        emit("info", main=main, size=total, files=len(infos))

        done, last, written, skipped = 0, 0.0, 0, 0
        for i in infos:
            parts = safe_parts(i.filename)
            if parts is None:
                skipped += 1
                continue
            target = os.path.join(dest, *parts)
            if i.is_dir():
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.exists(target):
                if os.path.getsize(target) == i.file_size:
                    done += i.file_size
                    skipped += 1
                    continue
                target = free_name(target)
            tmp = target + ".dualdl-unzip"
            with z.open(i) as src, open(tmp, "wb") as dst:
                while True:
                    block = src.read(1 << 20)
                    if not block:
                        break
                    dst.write(block)
                    done += len(block)
                    now = time.time()
                    if now - last > 0.5:
                        emit("progress", done=done, size=total)
                        last = now
            os.replace(tmp, target)       # a half-written file never has the real name
            mtime = time.mktime(i.date_time + (0, 0, -1))
            os.utime(target, (mtime, mtime))
            written += 1
        emit("done", main=main, files=written, skipped=skipped, size=total)


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        sys.exit(0 if len(sys.argv) == 2 else 2)
    try:
        extract(sys.argv[1])
    except SystemExit as e:
        if isinstance(e.code, str):
            emit("error", message=e.code)
            sys.exit(1)
        raise
    except KeyboardInterrupt:
        emit("paused")
        sys.exit(130)
    except Exception as e:
        emit("error", message="%s: %s" % (type(e).__name__, e))
        sys.exit(1)


if __name__ == "__main__":
    main()
