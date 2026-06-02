#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${VERSION:-2026.0.0.198}"
OS_ID="${OS_ID:-ubuntu_24.04}"
ARCH="${ARCH:-x86_64}"
INSTALLER_URL="${INSTALLER_URL:-https://registrationcenter-download.intel.com/akdlm/IRC_NAS/71180075-e4e3-4c6f-bbbb-19017ed0cf7d/intel-oneapi-toolkit-2026.0.0.198_offline.sh}"
ACCEPT_INTEL_EULA="${ACCEPT_INTEL_EULA:-}"
REPOSITORY="${REPOSITORY:-${GITHUB_REPOSITORY:-<owner>/rules-ml-toolchain-redists}}"
MAX_RELEASE_ASSET_BYTES="${MAX_RELEASE_ASSET_BYTES:-2000000000}"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-25000000000}"

major="${VERSION%%.*}"
rest="${VERSION#*.}"
minor="${rest%%.*}"
ONEAPI_SERIES="${ONEAPI_SERIES:-${major}.${minor}}"

COMPONENT_FILE="${COMPONENT_FILE:-${ROOT_DIR}/config/oneapi-${ONEAPI_SERIES}-${OS_ID}.components}"
WORK_DIR="${WORK_DIR:-${ROOT_DIR}/work}"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
STAGE_ROOT="${WORK_DIR}/stage"
INSTALL_DIR="${STAGE_ROOT}/oneapi"
INSTALLER_ENV_DIR="${WORK_DIR}/installer-env"

ARCHIVE_BASENAME="intel-oneapi-toolkit-${VERSION}-${OS_ID}-${ARCH}.tar.xz"
ARCHIVE="${DIST_DIR}/${ARCHIVE_BASENAME}"
SHA256_FILE="${ARCHIVE}.sha256"
METADATA_FILE="${DIST_DIR}/intel-oneapi-toolkit-${VERSION}-${OS_ID}-${ARCH}.json"
RELEASE_TAG="oneapi-v${VERSION}-${OS_ID}-${ARCH}"
RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ARCHIVE_BASENAME}"

if [[ "${ACCEPT_INTEL_EULA}" != "yes" ]]; then
  echo "Set ACCEPT_INTEL_EULA=yes to confirm Intel EULA acceptance before downloading or installing oneAPI." >&2
  exit 1
fi

if [[ ! -f "${COMPONENT_FILE}" ]]; then
  echo "component file not found: ${COMPONENT_FILE}" >&2
  exit 1
fi

required_tools=(curl df tar sha256sum python3)
for tool in "${required_tools[@]}"; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "required tool not found: ${tool}" >&2
    exit 1
  fi
done

components="$(paste -sd, "${COMPONENT_FILE}")"
if [[ -z "${components}" ]]; then
  echo "component list is empty: ${COMPONENT_FILE}" >&2
  exit 1
fi

available_bytes="$(df --output=avail -B1 "${ROOT_DIR}" | tail -n 1 | tr -d ' ')"
if (( available_bytes < MIN_FREE_BYTES )); then
  echo "insufficient disk space for oneAPI redist build" >&2
  echo "available: ${available_bytes} bytes" >&2
  echo "required: ${MIN_FREE_BYTES} bytes" >&2
  exit 1
fi

rm -rf "${DIST_DIR}" "${STAGE_ROOT}" "${INSTALLER_ENV_DIR}"
mkdir -p "${DIST_DIR}" "${DOWNLOAD_DIR}" "${STAGE_ROOT}" "${INSTALLER_ENV_DIR}/home" \
  "${INSTALLER_ENV_DIR}/cache" "${INSTALLER_ENV_DIR}/config" "${INSTALLER_ENV_DIR}/data"

installer_name="$(basename "${INSTALLER_URL%%\?*}")"
installer_path="${DOWNLOAD_DIR}/${installer_name}"

echo "Downloading ${INSTALLER_URL}"
curl --fail --location --retry 3 --retry-delay 10 --output "${installer_path}" "${INSTALLER_URL}"
chmod +x "${installer_path}"

echo "Installing oneAPI ${VERSION} into ${INSTALL_DIR}"
env \
  HOME="${INSTALLER_ENV_DIR}/home" \
  XDG_CACHE_HOME="${INSTALLER_ENV_DIR}/cache" \
  XDG_CONFIG_HOME="${INSTALLER_ENV_DIR}/config" \
  XDG_DATA_HOME="${INSTALLER_ENV_DIR}/data" \
  bash "${installer_path}" \
    -a \
    --silent \
    --eula accept \
    --components "${components}" \
    --install-dir "${INSTALL_DIR}"

echo "Pruning installer state"
rm -rf \
  "${INSTALL_DIR}/logs" \
  "${INSTALL_DIR}/.installer_cache" \
  "${INSTALL_DIR}/.installer_config" \
  "${INSTALL_DIR}/.installer_data" \
  "${INSTALL_DIR}/.installer_home"
find "${INSTALL_DIR}" -type f -name '*.log' -delete

echo "Creating ${ARCHIVE}"
tar \
  --sort=name \
  --mtime=@0 \
  --owner=0 \
  --group=0 \
  --numeric-owner \
  -C "${STAGE_ROOT}" \
  -cJf "${ARCHIVE}" \
  oneapi

archive_size="$(stat -c%s "${ARCHIVE}")"
if (( archive_size >= MAX_RELEASE_ASSET_BYTES )); then
  echo "archive is too large for a GitHub release asset: ${archive_size} bytes" >&2
  echo "limit: ${MAX_RELEASE_ASSET_BYTES} bytes" >&2
  exit 1
fi

ONEAPI_SERIES="${ONEAPI_SERIES}" "${ROOT_DIR}/scripts/verify_archive.sh" "${ARCHIVE}"

archive_sha256="$(sha256sum "${ARCHIVE}" | awk '{print $1}')"
printf '%s  %s\n' "${archive_sha256}" "${ARCHIVE_BASENAME}" > "${SHA256_FILE}"

component_file_metadata="${COMPONENT_FILE}"
if [[ "${component_file_metadata}" == "${ROOT_DIR}/"* ]]; then
  component_file_metadata="${component_file_metadata#"${ROOT_DIR}/"}"
fi

starlark_tuple="$(cat <<EOF
"${OS_ID}_${ONEAPI_SERIES}": [
    "${RELEASE_URL}",
    "${archive_sha256}",
    "oneapi",
],
EOF
)"

export VERSION OS_ID ARCH INSTALLER_URL component_file_metadata ARCHIVE_BASENAME archive_size \
  archive_sha256 RELEASE_TAG RELEASE_URL starlark_tuple METADATA_FILE
python3 - <<'PY'
import json
import os
from pathlib import Path

metadata = {
    "version": os.environ["VERSION"],
    "os_id": os.environ["OS_ID"],
    "arch": os.environ["ARCH"],
    "installer_url": os.environ["INSTALLER_URL"],
    "component_file": os.environ["component_file_metadata"],
    "archive_name": os.environ["ARCHIVE_BASENAME"],
    "archive_size": int(os.environ["archive_size"]),
    "sha256": os.environ["archive_sha256"],
    "release_tag": os.environ["RELEASE_TAG"],
    "release_url": os.environ["RELEASE_URL"],
    "starlark_tuple": os.environ["starlark_tuple"],
}

path = Path(os.environ["METADATA_FILE"])
path.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY

echo "Archive: ${ARCHIVE}"
echo "SHA256: ${archive_sha256}"
echo "Metadata: ${METADATA_FILE}"
echo
echo "Starlark tuple:"
printf '%s\n' "${starlark_tuple}"
