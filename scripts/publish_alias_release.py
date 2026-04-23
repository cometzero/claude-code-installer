#!/usr/bin/env python3
import argparse
import datetime as dt
import json
import pathlib
import subprocess
import sys
import tempfile


def run(*args, check=True, capture_output=False):
    return subprocess.run(args, check=check, text=True, capture_output=capture_output)


def release_exists(tag: str) -> bool:
    result = subprocess.run(["gh", "release", "view", tag], text=True, capture_output=True)
    return result.returncode == 0


def main():
    parser = argparse.ArgumentParser(description="Publish/update a lightweight alias release")
    parser.add_argument("--alias", required=True, choices=["latest", "stable"], help="Alias release tag to publish")
    parser.add_argument("--target-tag", required=True, help="Actual mirrored version tag, e.g. v2.1.118")
    parser.add_argument("--source-release", required=True, help="Upstream release URL")
    parser.add_argument("--manifest-path", required=True, help="Path to mirrored manifest.json for the target release")
    args = parser.parse_args()

    manifest = json.loads(pathlib.Path(args.manifest_path).read_text())
    alias_payload = {
        "alias": args.alias,
        "target_tag": args.target_tag,
        "version": manifest["version"],
        "source_repo": manifest["sourceRepo"],
        "source_release": args.source_release,
        "published_at": manifest["publishedAt"],
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }

    notes = f"""Alias release `{args.alias}` → `{args.target_tag}`.

This is a lightweight pointer release for installers.
It does not contain Claude binaries.

- Target mirrored release: https://github.com/cometzero/claude-code-installer/releases/tag/{args.target_tag}
- Upstream release: {args.source_release}
"""

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = pathlib.Path(tmp)
        alias_json = tmpdir / "alias.json"
        notes_file = tmpdir / "notes.md"
        alias_json.write_text(json.dumps(alias_payload, indent=2) + "\n")
        notes_file.write_text(notes)

        if release_exists(args.alias):
            run("gh", "release", "delete", args.alias, "--yes", "--cleanup-tag")

        run(
            "gh",
            "release",
            "create",
            args.alias,
            str(alias_json),
            "--title",
            f"{args.alias} -> {args.target_tag}",
            "--notes-file",
            str(notes_file),
        )

    print(json.dumps(alias_payload))


if __name__ == "__main__":
    main()
