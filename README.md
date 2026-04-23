# claude-code-installer

GitHub-hosted mirror installer for Claude Code.

This repository exists for environments where `claude.ai` / `downloads.claude.ai` is blocked but GitHub Releases is still reachable. It mirrors the official Claude Code release archives from [`anthropics/claude-code`](https://github.com/anthropics/claude-code/releases) into this repository's Releases and provides install scripts that download from this repo instead of `claude.ai`.

## What is mirrored

Each mirrored release tag includes these assets:

- `claude-darwin-arm64.tar.gz`
- `claude-darwin-x64.tar.gz`
- `claude-linux-arm64.tar.gz`
- `claude-linux-arm64-musl.tar.gz`
- `claude-linux-x64.tar.gz`
- `claude-linux-x64-musl.tar.gz`
- `claude-win32-arm64.zip`
- `claude-win32-x64.zip`
- `SHASUMS256.txt`
- `SHASUMS256.txt.sig`
- `manifest.json` generated for this mirror

The binaries are **not committed to git history**. They only live as release assets.

## Install

### macOS / Linux

```bash
curl -fsSL https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.sh | bash
```

Install a specific target:

```bash
curl -fsSL https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.sh | bash -s -- latest
curl -fsSL https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.sh | bash -s -- stable
curl -fsSL https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.sh | bash -s -- 2.1.118
```

### Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.ps1 | iex
```

Specific target:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.ps1))) latest
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.ps1))) stable
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/cometzero/claude-code-installer/main/install.ps1))) 2.1.118
```

## How it works

1. Resolve the requested version from this repo's GitHub Releases.
2. Detect OS / architecture / musl.
3. Download the matching mirrored archive from this repo's release assets.
4. Verify the archive checksum against `manifest.json` / upstream `SHASUMS256.txt`.
5. Extract `claude` / `claude.exe` temporarily.
6. Run `claude install [target]`.
7. Delete temporary downloaded artifacts.

## Automation

The workflow `.github/workflows/sync-upstream-release.yml` checks upstream Claude Code releases on a schedule and creates a same-tag mirror release in this repository when a new upstream release appears.

You can also run it manually with `workflow_dispatch` and optionally provide a specific tag.

## Provenance

- Upstream source: https://github.com/anthropics/claude-code
- Upstream release notes remain Anthropic's content.
- This repository only republishes release assets and thin installer scripts for compatibility in restricted networks.
