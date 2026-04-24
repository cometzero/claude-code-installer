#!/usr/bin/env bash

set -euo pipefail

TARGET="${1:-}"
if [[ -n "$TARGET" ]] && [[ ! "$TARGET" =~ ^(stable|latest|[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?)$ ]]; then
  echo "Usage: $0 [stable|latest|VERSION]" >&2
  exit 1
fi

REPO="${CLAUDE_CODE_INSTALL_REPO:-cometzero/claude-code-installer}"
API_BASE="https://api.github.com/repos/${REPO}"
DOWNLOAD_BASE="https://github.com/${REPO}/releases/download"
DOWNLOAD_DIR="${HOME}/.claude/downloads"
INSTALL_BASE_DIR="${HOME}/.claude/native"
BIN_DIR="${HOME}/.local/bin"
WORK_DIR=""
DOWNLOADER=""
HAS_JQ=false

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

if command -v curl >/dev/null 2>&1; then
  DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
  DOWNLOADER="wget"
else
  echo "Either curl or wget is required but neither is installed" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  HAS_JQ=true
fi

download_file() {
  local url="$1"
  local output="${2:-}"

  if [[ "$DOWNLOADER" == "curl" ]]; then
    if [[ -n "$output" ]]; then
      curl -fsSL -o "$output" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [[ -n "$output" ]]; then
      wget -q -O "$output" "$url"
    else
      wget -q -O - "$url"
    fi
  fi
}

normalize_tag() {
  local value="$1"
  if [[ -z "$value" || "$value" == "latest" || "$value" == "stable" ]]; then
    printf '%s' ""
  elif [[ "$value" =~ ^v ]]; then
    printf '%s' "$value"
  else
    printf 'v%s' "$value"
  fi
}

resolve_tag() {
  local requested="$1"
  local response

  if [[ -z "$requested" || "$requested" == "latest" || "$requested" == "stable" ]]; then
    local alias_name="${requested:-latest}"
    response=$(download_file "$DOWNLOAD_BASE/$alias_name/alias.json")
    if [[ "$HAS_JQ" == true ]]; then
      echo "$response" | jq -r '.target_tag'
    else
      echo "$response" | tr -d '\n\r' | sed -E 's/.*"target_tag"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi
  else
    response=$(download_file "$API_BASE/releases/tags/$(normalize_tag "$requested")")
    if [[ "$HAS_JQ" == true ]]; then
      echo "$response" | jq -r '.tag_name'
    else
      echo "$response" | tr -d '\n\r' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
    fi
  fi
}

get_manifest_field() {
  local json="$1"
  local platform="$2"
  local field="$3"

  if [[ "$HAS_JQ" == true ]]; then
    echo "$json" | jq -r ".platforms[\"$platform\"].$field // empty"
  else
    json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
    if [[ "$field" == "asset" ]]; then
      [[ $json =~ \"$platform\"[^}]*\"asset\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && echo "${BASH_REMATCH[1]}" && return 0
    elif [[ "$field" == "checksum" ]]; then
      [[ $json =~ \"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]] && echo "${BASH_REMATCH[1]}" && return 0
    elif [[ "$field" == "format" ]]; then
      [[ $json =~ \"$platform\"[^}]*\"format\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && echo "${BASH_REMATCH[1]}" && return 0
    elif [[ "$field" == "binary" ]]; then
      [[ $json =~ \"$platform\"[^}]*\"binary\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && echo "${BASH_REMATCH[1]}" && return 0
    fi
    return 1
  fi
}

case "$(uname -s)" in
  Darwin) os="darwin" ;;
  Linux) os="linux" ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Windows is not supported by this script. Use install.ps1 instead." >&2
    exit 1
    ;;
  *)
    echo "Unsupported operating system: $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch="x64" ;;
  arm64|aarch64) arch="arm64" ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$os" == "darwin" && "$arch" == "x64" ]]; then
  if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
    arch="arm64"
  fi
fi

if [[ "$os" == "linux" ]]; then
  if [[ -f /lib/libc.musl-x86_64.so.1 ]] || [[ -f /lib/libc.musl-aarch64.so.1 ]] || ldd /bin/ls 2>&1 | grep -q musl; then
    platform="linux-${arch}-musl"
  else
    platform="linux-${arch}"
  fi
else
  platform="${os}-${arch}"
fi

mkdir -p "$DOWNLOAD_DIR" "$INSTALL_BASE_DIR" "$BIN_DIR"
WORK_DIR=$(mktemp -d)

TAG=$(resolve_tag "$TARGET")
if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  echo "Unable to resolve release tag for target '${TARGET:-latest}'" >&2
  exit 1
fi

MANIFEST_URL="$DOWNLOAD_BASE/$TAG/manifest.json"
manifest_json=$(download_file "$MANIFEST_URL")
asset=$(get_manifest_field "$manifest_json" "$platform" asset)
checksum=$(get_manifest_field "$manifest_json" "$platform" checksum)
archive_format=$(get_manifest_field "$manifest_json" "$platform" format)
binary_name=$(get_manifest_field "$manifest_json" "$platform" binary)

if [[ -z "$asset" || -z "$checksum" || -z "$archive_format" || -z "$binary_name" ]]; then
  echo "Platform $platform not found in manifest for $TAG" >&2
  exit 1
fi

archive_path="$WORK_DIR/$asset"
extract_dir="$WORK_DIR/extracted"
mkdir -p "$extract_dir"

download_file "$DOWNLOAD_BASE/$TAG/$asset" "$archive_path"

if [[ "$os" == "darwin" ]]; then
  actual=$(shasum -a 256 "$archive_path" | cut -d' ' -f1)
else
  actual=$(sha256sum "$archive_path" | cut -d' ' -f1)
fi

if [[ "$actual" != "$checksum" ]]; then
  echo "Checksum verification failed for $asset" >&2
  exit 1
fi

case "$archive_format" in
  tar.gz)
    tar -xzf "$archive_path" -C "$extract_dir"
    ;;
  zip)
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$archive_path" "$extract_dir" <<'PY'
import sys, zipfile
archive, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(archive) as zf:
    zf.extractall(dest)
PY
    else
      echo "python3 is required to extract zip archives on this platform" >&2
      exit 1
    fi
    ;;
  *)
    echo "Unsupported archive format: $archive_format" >&2
    exit 1
    ;;
esac

binary_path="$extract_dir/$binary_name"
if [[ ! -f "$binary_path" ]]; then
  echo "Expected binary $binary_name not found in extracted archive" >&2
  exit 1
fi

install_dir="$INSTALL_BASE_DIR/$TAG/$platform"
installed_binary="$install_dir/claude"
wrapper_path="$BIN_DIR/claude"
mkdir -p "$install_dir"
install -m 755 "$binary_path" "$installed_binary"
cat > "$wrapper_path" <<EOF
#!/usr/bin/env bash
export DISABLE_UPDATES=1
exec "$installed_binary" "\$@"
EOF
chmod +x "$wrapper_path"

echo "Installed Claude Code binary to: $installed_binary"
echo "Installed launcher to: $wrapper_path"
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "Add $BIN_DIR to your PATH to run 'claude' directly."
fi

echo ""
echo "✅ Installation complete!"
echo ""
