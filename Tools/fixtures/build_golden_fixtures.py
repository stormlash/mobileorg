#!/usr/bin/env python3
"""Generate golden fixtures for the MobileOrg WebDAV regression harness.

For a fixture profile directory (MobileOrgTests/Resources/WebDavTests/
pristine/<profile>/) this script:

  1. Writes checksums.dat (md5sum format, "md5<2 spaces>filename") over the
     exact served bytes of every *.org / *.txt file in the profile.
  2. Writes golden-manifest.json: per-file expected node counts (replicating
     OrgFileParser's semantics: one level-0 file node per downloaded file plus
     one Node per heading line), per-heading structure with todo/priority/tag
     extraction and :ID: binding, and md5 digests for staged-file byte-identity
     assertions.

Profiles whose files are OpenSSL-encrypted (the legacy fixture uses the app's
AES-256-CBC scheme, EVP_BytesToKey with MD5) are handled by passing
--password; the script decrypts via the openssl CLI for parsing while checksums
and digests always cover the served (ciphertext) bytes.

The generated manifest is committed: CI and the tests consume it, they never
regenerate it. Validate the legacy profile with --expect-total 136 (the known
whole-tree node count from the fork audit).
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

HEADING_RE = re.compile(r"^(?P<stars>\*+)(?P<space> .*$)?$" +
                        r"", re.DOTALL)
# OrgFileParser: a heading is leading stars followed by a space (or end of line).
TODO_LINE_RE = re.compile(r"^#\+TODO:\s*(.*)$")
PRIORITY_RE = re.compile(r"^\[#([a-zA-Z0-9])\] (.+)$")
TAGS_RE = re.compile(r"^(.+?)\s+(:([\w@\.]+:)+)\s*$")
ID_LINE_RE = re.compile(r":ID:\s*(.+)$")

SALTED_MAGIC = b"Salted__"


def is_heading(line: str):
    """Mirror OrgFileParser's heading rule: stars, then a space (or EOL)."""
    if not line:
        return 0
    stars = 0
    while stars < len(line) and line[stars] == "*":
        stars += 1
    if stars == 0:
        return 0
    if stars >= len(line) or line[stars] != " ":
        return 0
    return stars


def parse_todo_words(index_text: str):
    """Collect (todo, done) keyword sets from the index's #+TODO: lines.

    Matches the app's registration: keywords before `|` are todo states,
    after `|` are done states. The `(t)`-style shortcuts are stripped.
    """
    todo, done = set(), set()
    for line in index_text.splitlines():
        m = TODO_LINE_RE.match(line)
        if not m:
            continue
        words = re.sub(r"\(\w\)", "", m.group(1))
        if "|" in words:
            left, right = words.split("|", 1)
        else:
            left, right = words, ""
            # No separator at all: the app treats the second whitespace token
            # group as done words only in its no-`|` regex branch, which real
            # staging files do not use; treat everything as todo.
        todo.update(w for w in left.split() if w)
        done.update(w for w in right.split() if w)
    return todo, done


def extract_heading(raw_title: str, todo_words, done_words, priorities):
    """Replicate the app's title extraction: todo keyword, priority, tags."""
    todo_state, priority, tags = "", "", ""
    title = raw_title.strip()
    first = title.split(" ", 1)
    if len(first) == 2 and (first[0] in todo_words or first[0] in done_words):
        todo_state, title = first[0], first[1].strip()
    m = PRIORITY_RE.match(title)
    if m and m.group(1) in priorities:
        priority, title = m.group(1), m.group(2)
    m = TAGS_RE.match(title)
    if m:
        title, tags = m.group(1), m.group(2)
    return title, todo_state, priority, tags


def parse_org_file(text: str, todo_words, done_words, priorities):
    """Return (heading_count, structure) mirroring OrgFileParser."""
    headings = 0
    structure = []
    last_level = None
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        stars = is_heading(line)
        if stars > 0:
            headings += 1
            raw = line[stars + 1:] if stars < len(line) else ""
            title, todo_state, priority, tags = extract_heading(
                raw, todo_words, done_words, priorities)
            entry = {"level": stars, "heading": title}
            if todo_state:
                entry["todo"] = todo_state
            if priority:
                entry["priority"] = priority
            if tags:
                entry["tags"] = tags
            # :ID: body lines bind edit actions to the preceding heading.
            # Look ahead for the app's rule (any following body line).
            structure.append(entry)
            last_level = stars
        elif line is not None and last_level is not None:
            m = ID_LINE_RE.search(line)
            if m and structure and "id" not in structure[-1]:
                structure[-1]["id"] = m.group(1).strip()
    return headings, structure


def maybe_decrypt(path: str, password: str | None) -> bytes:
    raw = open(path, "rb").read()
    if not raw.startswith(SALTED_MAGIC):
        return raw
    if not password:
        raise SystemExit(
            f"error: {path} is OpenSSL-encrypted; pass --password to decrypt")
    with tempfile.NamedTemporaryFile(suffix=".org", delete=False) as tmp:
        tmp.write(raw)
        tmp_path = tmp.name
    try:
        out = subprocess.run(
            ["openssl", "enc", "-d", "-aes-256-cbc", "-md", "md5",
             "-pass", f"pass:{password}", "-in", tmp_path],
            capture_output=True, check=True)
        return out.stdout
    finally:
        os.unlink(tmp_path)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--profile", required=True,
                    help="profile directory under pristine/ (or a path)")
    ap.add_argument("--password", default=None,
                    help="OpenSSL passphrase for encrypted profiles")
    ap.add_argument("--expect-total", type=int, default=None,
                    help="fail unless the generated totalNodes matches")
    ap.add_argument("--write-checksums", action="store_true",
                    help="write checksums.dat (default: leave any existing "
                         "file untouched; the legacy profile is frozen "
                         "upstream data with mixed md5/sha1 entries)")
    args = ap.parse_args()

    profile_dir = (args.profile if os.path.isdir(args.profile) else
                   os.path.join("MobileOrgTests", "Resources", "WebDavTests",
                                "pristine", args.profile))
    if not os.path.isdir(profile_dir):
        raise SystemExit(f"error: no such profile directory {profile_dir}")

    todo_words, done_words, priorities = set(), set(), {"A", "B", "C"}
    index_name = "index.org"
    index_path = os.path.join(profile_dir, index_name)
    if os.path.exists(index_path):
        index_text = maybe_decrypt(index_path, args.password).decode("utf-8")
        todo_words, done_words = parse_todo_words(index_text)
        for line in index_text.splitlines():
            m = re.match(r"^#\+ALLPRIORITIES:\s*(.*)$", line)
            if m:
                priorities.update(p for p in m.group(1).split() if p)

    files = {}
    names = sorted(
        n for n in os.listdir(profile_dir)
        if n != "checksums.dat" and n != "golden-manifest.json"
        and (n.endswith(".org") or n.endswith(".org.txt") or n.endswith(".txt")))
    new_checksums = []
    for name in names:
        path = os.path.join(profile_dir, name)
        raw = open(path, "rb").read()
        files[name] = {"md5": hashlib.md5(raw).hexdigest()}
        new_checksums.append(f"{files[name]['md5']}  {name}\n")

    checksums_path = os.path.join(profile_dir, "checksums.dat")
    if args.write_checksums:
        with open(checksums_path, "w", newline="") as fh:
            fh.write("".join(new_checksums))

    for name in names:
        text = maybe_decrypt(os.path.join(profile_dir, name),
                             args.password).decode("utf-8")
        headings, structure = parse_org_file(text, todo_words, done_words,
                                             priorities)
        # One level-0 file node per parsed file plus one node per heading.
        files[name]["headings"] = headings
        files[name]["count"] = headings + 1
        files[name]["structure"] = structure

    total = sum(f["count"] for f in files.values())
    manifest = {
        "profile": os.path.basename(profile_dir.rstrip("/")),
        "note": "Generated by Tools/fixtures/build_golden_fixtures.py — "
                "do not edit by hand.",
        "indexFile": index_name,
        "stagedFiles": [n for n in names if n != index_name
                        and n != "mobileorg.org"],
        "totalNodes": total,
        "files": files,
    }

    if args.expect_total is not None and total != args.expect_total:
        raise SystemExit(
            f"error: expected {args.expect_total} nodes, computed {total}")

    manifest_path = os.path.join(profile_dir, "golden-manifest.json")
    with open(manifest_path, "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print(f"profile {manifest['profile']}: {total} nodes across "
          f"{len(names)} files -> {checksums_path}, {manifest_path}")


if __name__ == "__main__":
    main()
