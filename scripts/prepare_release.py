#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import re
import textwrap
import urllib.request

UPSTREAM_REPO = "anthropics/claude-code"
ASSET_RE = re.compile(r"^claude-(darwin-(?:arm64|x64)|linux-(?:arm64|x64)(?:-musl)?|win32-(?:arm64|x64))\.(tar\.gz|zip)$")
EXTRA_ASSETS = {"SHASUMS256.txt", "SHASUMS256.txt.sig"}


def api_json(url: str):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "claude-code-installer-sync"})
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


def download(url: str, dest: pathlib.Path):
    req = urllib.request.Request(url, headers={"User-Agent": "claude-code-installer-sync"})
    with urllib.request.urlopen(req) as resp, dest.open("wb") as fh:
        while True:
            chunk = resp.read(1024 * 1024)
            if not chunk:
                break
            fh.write(chunk)


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def normalize_requested_tag(value: str) -> str:
    if value in ("", "latest", "stable"):
        return value
    return value if value.startswith("v") else f"v{value}"


def resolve_upstream_release(requested_tag: str):
    if requested_tag in ("", "latest", "stable"):
        return api_json(f"https://api.github.com/repos/{UPSTREAM_REPO}/releases/latest")
    tag = normalize_requested_tag(requested_tag)
    return api_json(f"https://api.github.com/repos/{UPSTREAM_REPO}/releases/tags/{tag}")


def parse_shasums(path: pathlib.Path):
    result = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        checksum, filename = line.split(None, 1)
        result[filename.strip()] = checksum.strip()
    return result


def build_manifest(release, out_dir: pathlib.Path, checksums: dict, mirrored_assets: list[str]):
    platforms = {}
    for asset_name in mirrored_assets:
        m = ASSET_RE.match(asset_name)
        if not m:
            continue
        platform, fmt = m.group(1), m.group(2)
        platforms[platform] = {
            "asset": asset_name,
            "checksum": checksums[asset_name],
            "format": fmt,
            "binary": "claude.exe" if platform.startswith("win32-") else "claude",
        }

    version = release["tag_name"][1:] if release["tag_name"].startswith("v") else release["tag_name"]
    manifest = {
        "version": version,
        "tag": release["tag_name"],
        "sourceRepo": UPSTREAM_REPO,
        "sourceRelease": release["html_url"],
        "publishedAt": release["published_at"],
        "platforms": platforms,
    }
    manifest_path = out_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest_path


def build_release_notes(release, out_dir: pathlib.Path, mirrored_assets: list[str]):
    body = release.get("body") or ""
    notes = textwrap.dedent(
        f"""\
        Mirrored release for upstream Claude Code `{release['tag_name']}`.

        - Upstream repo: https://github.com/{UPSTREAM_REPO}
        - Upstream release: {release['html_url']}
        - Published at: {release['published_at']}
        - Mirrored assets: {len(mirrored_assets)}

        ## Upstream release notes

        {body}
        """
    )
    notes_path = out_dir / "release-notes.md"
    notes_path.write_text(notes)
    return notes_path


def main():
    parser = argparse.ArgumentParser(description="Prepare mirrored Claude Code release assets")
    parser.add_argument("--tag", default="latest", help="Upstream tag to mirror: latest|stable|vX.Y.Z|X.Y.Z")
    parser.add_argument("--out-dir", required=True, help="Directory to write prepared assets into")
    args = parser.parse_args()

    out_dir = pathlib.Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    release = resolve_upstream_release(args.tag)
    wanted_names = []
    for asset in release.get("assets", []):
        name = asset["name"]
        if ASSET_RE.match(name) or name in EXTRA_ASSETS:
            wanted_names.append((name, asset["browser_download_url"]))

    if not wanted_names:
        raise SystemExit("No matching upstream assets found")

    mirrored_names = []
    for name, url in wanted_names:
        dest = out_dir / name
        print(f"Downloading {name}...")
        download(url, dest)
        mirrored_names.append(name)

    shasums_path = out_dir / "SHASUMS256.txt"
    if not shasums_path.exists():
        raise SystemExit("SHASUMS256.txt was not downloaded")
    checksums = parse_shasums(shasums_path)

    for name in mirrored_names:
        if name in EXTRA_ASSETS:
            continue
        expected = checksums.get(name)
        if not expected:
            raise SystemExit(f"Missing checksum for {name} in SHASUMS256.txt")
        actual = sha256_file(out_dir / name)
        if actual != expected:
            raise SystemExit(f"Checksum mismatch for {name}: expected {expected}, got {actual}")

    manifest_path = build_manifest(release, out_dir, checksums, mirrored_names)
    notes_path = build_release_notes(release, out_dir, mirrored_names)

    meta = {
        "tag": release["tag_name"],
        "version": release["tag_name"].removeprefix("v"),
        "source_release": release["html_url"],
        "assets": mirrored_names + [manifest_path.name],
        "notes": notes_path.name,
    }
    (out_dir / "release-meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    print(json.dumps(meta))


if __name__ == "__main__":
    main()
