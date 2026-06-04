#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:-}"
PACKAGE="${PACKAGE:-}"
OS_ID="${OS_ID:-}"
ARCH="${ARCH:-x86_64}"
MUSA_SOURCE_URL="${MUSA_SOURCE_URL:-}"
MUSA_SOURCE_SHA256="${MUSA_SOURCE_SHA256:-}"
MUSA_SOURCE_STRIP_PREFIX="${MUSA_SOURCE_STRIP_PREFIX:-}"
MUSA_SOURCE_KIND="${MUSA_SOURCE_KIND:-archive}"
MUSA_APT_REPOSITORY="${MUSA_APT_REPOSITORY:-https://dl.mthreads.com/repo/repository/ubuntu2204}"
MUSA_APT_DISTRIBUTION="${MUSA_APT_DISTRIBUTION:-jammy}"
MUSA_APT_COMPONENT="${MUSA_APT_COMPONENT:-main}"
MUSA_APT_BINARY_ARCH="${MUSA_APT_BINARY_ARCH:-amd64}"
MUSA_APT_PACKAGES="${MUSA_APT_PACKAGES:-}"
MUSA_DEVICE="${MUSA_DEVICE:-}"
ACCEPT_MUSA_TERMS="${ACCEPT_MUSA_TERMS:-}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-<owner>/rules-ml-toolchain-redists}}"
MAX_RELEASE_ASSET_BYTES="${MAX_RELEASE_ASSET_BYTES:-2147483648}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-25000000000}"
ZSTD_LEVEL="${ZSTD_LEVEL:-22}"
ZSTD_THREADS="${ZSTD_THREADS:-0}"

WORK_DIR="${WORK_DIR:-${ROOT_DIR}/work}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
SOURCE_DIR="${WORK_DIR}/musa-source"
APT_ROOT="${WORK_DIR}/musa-apt-root"
APT_MANIFEST="${WORK_DIR}/musa-apt-packages.tsv"
STAGE_ROOT="${WORK_DIR}/musa-stage"
INSTALL_DIR="${STAGE_ROOT}/musa"

ARCHIVE_BASENAME="musa-toolkit-${VERSION}-${PACKAGE}-${OS_ID}-${ARCH}.tar.zst"
ARCHIVE="${DIST_DIR}/${ARCHIVE_BASENAME}"
SHA256_FILE="${ARCHIVE}.sha256"
METADATA_FILE="${DIST_DIR}/musa-toolkit-${VERSION}-${PACKAGE}-${OS_ID}-${ARCH}.json"
RELEASE_TAG="musa-v${VERSION}-${PACKAGE}-${OS_ID}-${ARCH}"
RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ARCHIVE_BASENAME}"

fail() {
  echo "$*" >&2
  exit 1
}

require_value() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    fail "${name} is required"
  fi
}

validate_identifier() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
    fail "${name} may only contain letters, numbers, '.', '_', and '-': ${value}"
  fi
}

validate_source_kind() {
  case "$MUSA_SOURCE_KIND" in
    archive|apt)
      ;;
    *)
      fail "MUSA_SOURCE_KIND must be 'archive' or 'apt': ${MUSA_SOURCE_KIND}"
      ;;
  esac
}

normalize_device() {
  local device="$1"
  device="${device#MTT }"
  printf '%s\n' "${device^^}"
}

infer_musa_device() {
  local package="$1"

  case "$package" in
    *s80*|*cc2_1*|*chunxiao*)
      echo "S80"
      ;;
    *s3000*)
      echo "S3000"
      ;;
    *cc2_2*|*s4000*)
      echo "S4000"
      ;;
    *cc3_1*|*s5000*)
      echo "S5000"
      ;;
    *)
      echo ""
      ;;
  esac
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "required tool not found: $1"
  fi
}

extract_archive() {
  local archive="$1"
  local output_dir="$2"

  case "$archive" in
    *.tar.zst|*.tzst)
      require_tool zstd
      zstd -dc "$archive" | tar -C "$output_dir" -xf -
      ;;
    *.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar)
      tar -C "$output_dir" -xf "$archive"
      ;;
    *.zip)
      require_tool unzip
      unzip -q "$archive" -d "$output_dir"
      ;;
    *)
      fail "unsupported MUSA source archive format: $archive"
      ;;
  esac
}

find_toolkit_root() {
  local source_dir="$1"
  local strip_prefix="$2"

  if [[ -n "$strip_prefix" ]]; then
    local stripped="${source_dir}/${strip_prefix%/}"
    if [[ ! -d "$stripped" ]]; then
      fail "MUSA_SOURCE_STRIP_PREFIX did not resolve to a directory: $strip_prefix"
    fi
    echo "$stripped"
    return
  fi

  python3 - "$source_dir" <<'PY'
import os
import sys
from pathlib import Path

source = Path(sys.argv[1])
matches = []
for path in source.rglob("bin/mcc"):
    if path.is_file():
        matches.append(path.parent.parent)

if not matches:
    sys.exit("unable to locate MUSA toolkit root: missing bin/mcc")

matches.sort(key=lambda p: (len(p.parts), str(p)))
print(matches[0])
PY
}

find_library() {
  local root="$1"
  local soname="$2"
  find "$root" -type f \( -name "$soname" -o -name "${soname}.*" \) -print -quit
}

validate_toolkit_root() {
  local root="$1"
  local missing=()

  if [[ ! -x "$root/bin/mcc" && ! -f "$root/bin/mcc" ]]; then
    missing+=("bin/mcc")
  fi
  if [[ ! -d "$root/include" ]]; then
    missing+=("include")
  fi

  for lib in libmusart.so libmublas.so libmudnn.so; do
    if [[ -z "$(find_library "$root" "$lib")" ]]; then
      missing+=("$lib")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    fail "invalid MUSA toolkit root '${root}'. Missing required components: ${missing[*]}"
  fi
}

version_series() {
  local version="$1"
  local major="${version%%.*}"
  local rest="${version#*.}"
  local minor="${rest%%.*}"

  if [[ "$version" == "$rest" || -z "$major" || -z "$minor" ]]; then
    fail "VERSION must contain major.minor components for APT package defaults: ${version}"
  fi

  printf '%s-%s\n' "$major" "$minor"
}

default_musa_apt_packages() {
  local series
  local device
  series="$(version_series "$VERSION")"
  device="$(normalize_device "$MUSA_DEVICE")"
  local packages=(
    "musa-toolkit-${series}"
    "libmthreads-compute"
  )

  case "$series" in
    5-1)
      packages+=(
        "libmudnn3-musa-5"
        "libmudnn3-musa-5-dev"
      )
      ;;
  esac

  case "$device" in
    S5000)
      packages+=("mccl-s5000" "mccl-s5000-dev")
      ;;
    S4000)
      packages+=("mccl-s4000" "mccl-s4000-dev")
      ;;
    S80|S3000)
      ;;
  esac

  printf '%s\n' "${packages[*]}"
}

packages_to_json() {
  local manifest="$1"
  python3 - "$manifest" <<'PY'
import csv
import json
import sys
from pathlib import Path

rows = []
with Path(sys.argv[1]).open(newline="") as f:
    for row in csv.reader(f, delimiter="\t"):
        if not row:
            continue
        name, version, filename, sha256, size = row
        rows.append({
            "name": name,
            "version": version,
            "filename": filename,
            "sha256": sha256,
            "size": int(size or 0),
        })
print(json.dumps(rows, sort_keys=True))
PY
}

copy_apt_runtime_files() {
  local apt_root="$1"

  mkdir -p "$INSTALL_DIR/lib"
  while IFS= read -r path; do
    cp -a "$path" "$INSTALL_DIR/lib/"
  done < <(
    find "$apt_root" -type f,l \( \
      -name 'libmusa.so*' -o \
      -name 'libcuda2musa.so*' \
    \) -print
  )
}

stage_archive_source() {
  local source_name
  local source_path
  source_name="$(basename "${MUSA_SOURCE_URL%%\?*}")"
  source_path="${DOWNLOAD_DIR}/${source_name}"

  echo "Downloading MUSA source archive"
  curl --fail --location --retry 3 --retry-delay 10 --output "$source_path" "$MUSA_SOURCE_URL"

  echo "${MUSA_SOURCE_SHA256}  ${source_path}" | sha256sum --check --status || {
    actual_sha256="$(sha256sum "$source_path" | awk '{print $1}')"
    echo "MUSA source sha256 mismatch" >&2
    echo "expected: ${MUSA_SOURCE_SHA256}" >&2
    echo "actual:   ${actual_sha256}" >&2
    exit 1
  }

  echo "Extracting MUSA source archive"
  extract_archive "$source_path" "$SOURCE_DIR"

  toolkit_root="$(find_toolkit_root "$SOURCE_DIR" "$MUSA_SOURCE_STRIP_PREFIX")"
  validate_toolkit_root "$toolkit_root"

  echo "Staging MUSA toolkit from ${toolkit_root}"
  mkdir -p "$INSTALL_DIR"
  tar -C "$toolkit_root" -cf - . | tar -C "$INSTALL_DIR" -xf -
}

stage_apt_source() {
  local apt_repository="${MUSA_APT_REPOSITORY%/}"
  local packages_url="${apt_repository}/dists/${MUSA_APT_DISTRIBUTION}/${MUSA_APT_COMPONENT}/binary-${MUSA_APT_BINARY_ARCH}/Packages.gz"
  local packages_gz="${DOWNLOAD_DIR}/musa-apt-Packages.gz"
  local packages_txt="${WORK_DIR}/musa-apt-Packages"
  local root_packages="${MUSA_APT_PACKAGES}"

  if [[ -z "$root_packages" ]]; then
    root_packages="$(default_musa_apt_packages)"
  fi

  echo "Downloading MUSA APT package index"
  curl --fail --location --retry 3 --retry-delay 10 --output "$packages_gz" "$packages_url"
  APT_PACKAGES_INDEX_SHA256="$(sha256sum "$packages_gz" | awk '{print $1}')"
  gzip -dc "$packages_gz" > "$packages_txt"

  echo "Resolving MUSA APT packages: ${root_packages}"
  python3 "${ROOT_DIR}/scripts/resolve_musa_apt_packages.py" \
    --packages-file "$packages_txt" \
    --root-packages "$root_packages" \
    > "$APT_MANIFEST"

  mkdir -p "$APT_ROOT" "${DOWNLOAD_DIR}/apt"

  while IFS=$'\t' read -r name version filename sha256 size; do
    if [[ -z "$name" ]]; then
      continue
    fi

    deb_path="${DOWNLOAD_DIR}/apt/${filename//\//_}"
    echo "Downloading ${name} ${version} (${size} bytes)"
    curl --fail --location --retry 3 --retry-delay 10 \
      --output "$deb_path" \
      "${apt_repository}/${filename}"

    echo "${sha256}  ${deb_path}" | sha256sum --check --status || {
      actual_sha256="$(sha256sum "$deb_path" | awk '{print $1}')"
      echo "APT package sha256 mismatch for ${name}" >&2
      echo "expected: ${sha256}" >&2
      echo "actual:   ${actual_sha256}" >&2
      exit 1
    }

    dpkg-deb -x "$deb_path" "$APT_ROOT"
  done < "$APT_MANIFEST"

  toolkit_root="$(find_toolkit_root "$APT_ROOT" "")"
  validate_toolkit_root "$toolkit_root"

  echo "Staging MUSA toolkit from ${toolkit_root}"
  mkdir -p "$INSTALL_DIR"
  tar -C "$toolkit_root" -cf - . | tar -C "$INSTALL_DIR" -xf -
  copy_apt_runtime_files "$APT_ROOT"
}

if [[ "$ACCEPT_MUSA_TERMS" != "yes" ]]; then
  fail "Set ACCEPT_MUSA_TERMS=yes to confirm MUSA SDK license and redistribution approval before downloading or packaging MUSA."
fi

require_value VERSION "$VERSION"
require_value PACKAGE "$PACKAGE"
require_value OS_ID "$OS_ID"
require_value ARCH "$ARCH"
validate_source_kind

if [[ "$MUSA_SOURCE_KIND" == "archive" ]]; then
  require_value MUSA_SOURCE_URL "$MUSA_SOURCE_URL"
  require_value MUSA_SOURCE_SHA256 "$MUSA_SOURCE_SHA256"
else
  require_value MUSA_APT_REPOSITORY "$MUSA_APT_REPOSITORY"
  require_value MUSA_APT_DISTRIBUTION "$MUSA_APT_DISTRIBUTION"
  require_value MUSA_APT_COMPONENT "$MUSA_APT_COMPONENT"
  require_value MUSA_APT_BINARY_ARCH "$MUSA_APT_BINARY_ARCH"
fi

validate_identifier VERSION "$VERSION"
validate_identifier PACKAGE "$PACKAGE"
validate_identifier OS_ID "$OS_ID"
validate_identifier ARCH "$ARCH"

if [[ -z "$MUSA_DEVICE" ]]; then
  MUSA_DEVICE="$(infer_musa_device "$PACKAGE")"
fi
if [[ -n "$MUSA_DEVICE" ]]; then
  MUSA_DEVICE="$(normalize_device "$MUSA_DEVICE")"
fi

if [[ "$MUSA_SOURCE_KIND" == "apt" && "$MUSA_DEVICE" =~ ^(S80|S3000)$ ]]; then
  fail "MUSA_SOURCE_KIND=apt is not supported for MTT ${MUSA_DEVICE}. Use MUSA_SOURCE_KIND=archive with an approved S80/S3000 SDK archive, such as package musa_sdk_rc3_1_1."
fi

if (( ZSTD_LEVEL < 1 || ZSTD_LEVEL > 22 )); then
  fail "ZSTD_LEVEL must be between 1 and 22: ${ZSTD_LEVEL}"
fi

required_tools=(curl df find sha256sum stat tar python3 zstd)
if [[ "$MUSA_SOURCE_KIND" == "archive" ]]; then
  required_tools+=(basename)
else
  required_tools+=(dpkg-deb gzip)
fi
for tool in "${required_tools[@]}"; do
  require_tool "$tool"
done

available_bytes="$(df --output=avail -B1 "$ROOT_DIR" | tail -n 1 | tr -d ' ')"
if (( available_bytes < MIN_FREE_BYTES )); then
  echo "insufficient disk space for MUSA redist build" >&2
  echo "available: ${available_bytes} bytes" >&2
  echo "required: ${MIN_FREE_BYTES} bytes" >&2
  exit 1
fi

rm -rf "$DIST_DIR" "$SOURCE_DIR" "$APT_ROOT" "$STAGE_ROOT"
mkdir -p "$DIST_DIR" "$DOWNLOAD_DIR" "$SOURCE_DIR" "$STAGE_ROOT"

APT_PACKAGES_INDEX_SHA256=""
APT_PACKAGES_JSON="[]"

case "$MUSA_SOURCE_KIND" in
  archive)
    stage_archive_source
    ;;
  apt)
    stage_apt_source
    APT_PACKAGES_JSON="$(packages_to_json "$APT_MANIFEST")"
    ;;
esac

echo "Pruning generated or installer state"
find "$INSTALL_DIR" -type f \( -name '*.log' -o -name '*.tmp' \) -delete
find "$INSTALL_DIR" -type d \( \
  -name logs -o \
  -name '.cache' -o \
  -name '__pycache__' -o \
  -name '.installer_cache' -o \
  -name '.installer_config' -o \
  -name '.installer_data' -o \
  -name '.installer_home' \
  \) -prune -exec rm -rf {} +

zstd_args=(--no-progress "-T${ZSTD_THREADS}")
if (( ZSTD_LEVEL > 19 )); then
  zstd_args+=(--ultra)
fi
zstd_args+=("-${ZSTD_LEVEL}")

echo "Creating ${ARCHIVE} with zstd level ${ZSTD_LEVEL}"
tar \
  --sort=name \
  --mtime=@0 \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -C "$STAGE_ROOT" \
  -cf - \
  musa | zstd "${zstd_args[@]}" -o "$ARCHIVE" -

archive_size="$(stat -c%s "$ARCHIVE")"
if (( archive_size >= MAX_RELEASE_ASSET_BYTES )); then
  echo "archive is too large for a GitHub release asset: ${archive_size} bytes" >&2
  echo "limit: ${MAX_RELEASE_ASSET_BYTES} bytes" >&2
  exit 1
fi

"${ROOT_DIR}/scripts/verify_musa_archive.sh" "$ARCHIVE"

archive_sha256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$archive_sha256" "$ARCHIVE_BASENAME" > "$SHA256_FILE"

starlark_kwargs="$(cat <<EOF
url = "${RELEASE_URL}",
sha256 = "${archive_sha256}",
strip_prefix = "",
root = "musa",
EOF
)"

starlark_update="$(cat <<EOF
# Add these keyword arguments to MUSA_REDIST["${PACKAGE}"]:
${starlark_kwargs}
EOF
)"

export VERSION PACKAGE OS_ID ARCH MUSA_DEVICE MUSA_SOURCE_KIND MUSA_SOURCE_SHA256 \
  MUSA_SOURCE_STRIP_PREFIX MUSA_APT_REPOSITORY MUSA_APT_DISTRIBUTION \
  MUSA_APT_COMPONENT MUSA_APT_BINARY_ARCH APT_PACKAGES_INDEX_SHA256 \
  APT_PACKAGES_JSON ARCHIVE_BASENAME archive_size ZSTD_LEVEL archive_sha256 \
  RELEASE_TAG RELEASE_URL starlark_kwargs starlark_update METADATA_FILE
python3 - <<'PY'
import json
import os
from pathlib import Path

metadata = {
    "version": os.environ["VERSION"],
    "package": os.environ["PACKAGE"],
    "os_id": os.environ["OS_ID"],
    "arch": os.environ["ARCH"],
    "device": os.environ["MUSA_DEVICE"],
    "source_kind": os.environ["MUSA_SOURCE_KIND"],
    "source_sha256": os.environ["MUSA_SOURCE_SHA256"],
    "source_strip_prefix": os.environ["MUSA_SOURCE_STRIP_PREFIX"],
    "archive_name": os.environ["ARCHIVE_BASENAME"],
    "archive_size": int(os.environ["archive_size"]),
    "compression": "zstd",
    "sha256": os.environ["archive_sha256"],
    "release_tag": os.environ["RELEASE_TAG"],
    "release_url": os.environ["RELEASE_URL"],
    "starlark_kwargs": os.environ["starlark_kwargs"],
    "starlark_update": os.environ["starlark_update"],
    "zstd_level": int(os.environ["ZSTD_LEVEL"]),
}

if metadata["source_kind"] == "apt":
    metadata.update({
        "apt_repository": os.environ["MUSA_APT_REPOSITORY"],
        "apt_distribution": os.environ["MUSA_APT_DISTRIBUTION"],
        "apt_component": os.environ["MUSA_APT_COMPONENT"],
        "apt_binary_arch": os.environ["MUSA_APT_BINARY_ARCH"],
        "apt_packages_index_sha256": os.environ["APT_PACKAGES_INDEX_SHA256"],
        "apt_packages": json.loads(os.environ["APT_PACKAGES_JSON"]),
    })

path = Path(os.environ["METADATA_FILE"])
path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY

echo "Archive: ${ARCHIVE}"
echo "SHA256: ${archive_sha256}"
echo "Metadata: ${METADATA_FILE}"
echo
echo "Starlark update:"
printf '%s\n' "$starlark_update"
