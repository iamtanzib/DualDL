#!/usr/bin/env python3
"""Fake Google Drive folder pages + files for the manager test (served by range_server.py).

    python3 make_drive_fixtures.py <server folder>
"""
import os
import sys

S = sys.argv[1]


def entry(eid, href, name):
    return ('<div class="flip-entry" id="entry-%s" tabindex="0" role="link"><div class="flip-entry-info">'
            '<a href="%s" target="_blank"><div class="flip-entry-visual"></div>'
            '<div class="flip-entry-title">%s</div></a></div></div>' % (eid, href, name))


pages = {"F1": ("Test Folder", [entry("fileA", "https://drive.google.com/file/d/fileA/view?usp=drive_web", "A clip.mov"),
                                entry("fileB", "https://drive.google.com/file/d/fileB/view?usp=drive_web", "B clip.mov"),
                                entry("F2", "https://drive.google.com/drive/folders/F2", "Sub")]),
         "F2": ("Sub", [entry("fileC", "https://drive.google.com/file/d/fileC/view?usp=drive_web", "C clip.mov")])}
for fid, (title, entries) in pages.items():
    with open(os.path.join(S, "folder-%s.html" % fid), "w") as f:
        f.write("<html><head><title>%s</title></head><body>%s</body></html>" % (title, "".join(entries)))
for n in ("fileA", "fileB", "fileC", "retry.bin"):
    with open(os.path.join(S, n), "wb") as f:
        f.write(os.urandom(6 << 20))
