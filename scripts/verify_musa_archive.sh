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

if ! grep -Eq '^musa/?$|^musa/' "$listing"; then
  echo "archive does not contain top-level musa/ directory" >&2
  exit 1
fi

if grep -Ev '^musa/?$|^musa/' "$listing" >/dev/null; then
  echo "archive contains paths outside musa/" >&2
  grep -Ev '^musa/?$|^musa/' "$listing" >&2
  exit 1
fi

if ! grep -Fx "musa/bin/mcc" "$listing" >/dev/null; then
  echo "required path missing from archive: musa/bin/mcc" >&2
  exit 1
fi

if ! grep -Eq '^musa/include/?$|^musa/include/' "$listing"; then
  echo "required include directory missing from archive: musa/include" >&2
  exit 1
fi

required_libs=(
  libmusart.so
  libmublas.so
  libmudnn.so
)

for lib in "${required_libs[@]}"; do
  escaped_lib="${lib//./\\.}"
  if ! grep -Eq "^musa/.*/${escaped_lib}(\\.|$)|^musa/${escaped_lib}(\\.|$)" "$listing"; then
    echo "required library missing from archive: ${lib}" >&2
    exit 1
  fi
done

echo "archive verified: $archive"
