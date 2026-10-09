#!/usr/bin/env bash
# Downloads the bundled Whisper model into ./Model and verifies every file against
# scripts/model-manifest.txt (pinned Hugging Face commits + SHA-256). Idempotent.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$root/scripts/model-manifest.txt"
dest="$root/Model"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

mkdir -p "$dest"
while read -r expected remote path; do
    [[ -z "$expected" || "$expected" == \#* ]] && continue
    case "$path" in /* | *..*) echo "refusing unsafe path: $path" >&2; exit 1 ;; esac

    target="$dest/$path"
    if [[ -f "$target" && "$(sha256 "$target")" == "$expected" ]]; then
        continue
    fi

    echo "↓ $path"
    mkdir -p "$(dirname "$target")"
    tmp="$(mktemp "$dest/.download.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
        --output "$tmp" "https://huggingface.co/$remote"

    actual="$(sha256 "$tmp")"
    if [[ "$actual" != "$expected" ]]; then
        echo "checksum mismatch for $path: expected $expected, got $actual" >&2
        exit 1
    fi
    mv "$tmp" "$target"
    trap - EXIT
done < "$manifest"

echo "✓ Model verified in $dest"
