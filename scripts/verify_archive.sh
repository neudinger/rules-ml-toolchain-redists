#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 ARCHIVE.tar.zst" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

archive="$1"
oneapi_series="${ONEAPI_SERIES:-2026.0}"

if [[ ! -f "$archive" ]]; then
  echo "archive not found: $archive" >&2
  exit 1
fi

listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT

case "$archive" in
  *.tar.zst)
    if ! command -v zstd >/dev/null 2>&1; then
      echo "required tool not found: zstd" >&2
      exit 1
    fi
    zstd -dc "$archive" | tar -tf - > "$listing"
    ;;
  *)
    tar -tf "$archive" > "$listing"
    ;;
esac

if ! grep -Eq '^oneapi/?$|^oneapi/' "$listing"; then
  echo "archive does not contain top-level oneapi/ directory" >&2
  exit 1
fi

if grep -Ev '^oneapi/?$|^oneapi/' "$listing" >/dev/null; then
  echo "archive contains paths outside oneapi/" >&2
  grep -Ev '^oneapi/?$|^oneapi/' "$listing" >&2
  exit 1
fi

required_paths=(
  "oneapi/compiler/${oneapi_series}/bin/icpx"
  "oneapi/compiler/${oneapi_series}/bin/compiler/clang"
  "oneapi/compiler/${oneapi_series}/lib/libsycl.so.9"
)

for path in "${required_paths[@]}"; do
  if ! grep -Fx "$path" "$listing" >/dev/null; then
    echo "required path missing from archive: $path" >&2
    exit 1
  fi
done

escaped_series="${oneapi_series//./\\.}"
if ! grep -Eq "^oneapi/${escaped_series}/lib/libur_loader\\.so" "$listing"; then
  echo "required libur_loader library missing from archive" >&2
  exit 1
fi

echo "archive verified: $archive"
