# rules-ml-toolchain-redists

This repository builds redistribution archives consumed by
`rules_ml_toolchain`.

The supported artifacts are minimal Intel oneAPI and Moore Threads MUSA toolkit
archives. They are produced by manual GitHub Actions workflows. Vendor
installers, source SDK archives, and generated redist archives are not checked
into this repository.

## License

The scripts in this repository are licensed under Apache-2.0. Intel oneAPI,
Moore Threads MUSA, and generated archives are subject to their vendor licenses.
The workflows require explicit confirmation before downloading, installing, or
packaging vendor SDKs, but that confirmation is not a substitute for maintainer
or legal approval to publish the resulting archive.

## Build A oneAPI Release

Run the `Build oneAPI redist` workflow manually.

Use the defaults for the first archive:

- `version`: `2026.0.0.198`
- `os_id`: `ubuntu_24.04`
- `arch`: `x86_64`
- `accept_intel_eula`: `true`

The workflow publishes a GitHub release:

```text
oneapi-v2026.0.0.198-ubuntu_24.04-x86_64
```

with these release assets:

```text
intel-oneapi-toolkit-2026.0.0.198-ubuntu_24.04-x86_64.tar.zst
intel-oneapi-toolkit-2026.0.0.198-ubuntu_24.04-x86_64.tar.zst.sha256
intel-oneapi-toolkit-2026.0.0.198-ubuntu_24.04-x86_64.json
```

## Build A MUSA Release

Run the `Build MUSA redist` workflow manually.

Provide these inputs:

- `version`: MUSA SDK version, for example `5.1.0`.
- `package`: matching `MUSA_REDIST` key from
  `rules_ml_toolchain/gpu/musa/musa_redist.bzl`, for example
  `musa_sdk_5_1_0_cc2_2_deb`.
- `os_id`: target OS identifier, for example `ubuntu`.
- `arch`: target architecture, currently `x86_64`.
- `musa_source_url`: explicit MUSA SDK archive URL, or set
  `MUSA_SOURCE_URL` as a repository secret or variable.
- `musa_source_sha256`: explicit source archive sha256, or set
  `MUSA_SOURCE_SHA256` as a repository secret or variable.
- `accept_musa_terms`: `true`.

The workflow publishes a GitHub release:

```text
musa-v<version>-<package>-<os_id>-<arch>
```

with these release assets:

```text
musa-toolkit-<version>-<package>-<os_id>-<arch>.tar.zst
musa-toolkit-<version>-<package>-<os_id>-<arch>.tar.zst.sha256
musa-toolkit-<version>-<package>-<os_id>-<arch>.json
```

The archive is compressed with zstd at level 22 by default. GitHub release
assets must be smaller than 2 GiB. The build fails if the archive is too large.
If that happens, use S3, CloudFront, or GCS instead of GitHub Releases for the
final Bazel URL.

## Use From rules_ml_toolchain

After publishing a release, copy the generated tuple from the release notes or
JSON metadata into `gpu/sycl/sycl_redist_versions.bzl`:

```starlark
"ubuntu_24.04_2026.0": [
    "https://github.com/<owner>/rules-ml-toolchain-redists/releases/download/oneapi-v2026.0.0.198-ubuntu_24.04-x86_64/intel-oneapi-toolkit-2026.0.0.198-ubuntu_24.04-x86_64.tar.zst",
    "<sha256>",
    "oneapi",
],
```

Then validate in `rules_ml_toolchain`:

```bash
bazel query //gpu/sycl:oneapi_2026.BUILD
bazel build //cc/tests/gpu/sycl:all \
  --config=sycl_hermetic \
  --config=icpx_clang \
  --repo_env=ONEAPI_VERSION=2026.0 \
  --repo_env=OS=ubuntu_24.04
```

After publishing a MUSA release, copy the generated keyword arguments from the
release notes or JSON metadata into the matching `MUSA_REDIST` entry in
`gpu/musa/musa_redist.bzl`:

```starlark
"musa_sdk_5_1_0_cc2_2_deb": _entry(
    "5.1.0",
    ["5.1.0"],
    ["MTT S4000"],
    ["Ubuntu"],
    "2051875072112726016",
    "MUSA_SDK_5.1.0.CC2.2.DEB",
    "deb",
    url = "https://github.com/<owner>/rules-ml-toolchain-redists/releases/download/musa-v5.1.0-musa_sdk_5_1_0_cc2_2_deb-ubuntu-x86_64/musa-toolkit-5.1.0-musa_sdk_5_1_0_cc2_2_deb-ubuntu-x86_64.tar.zst",
    sha256 = "<sha256>",
    strip_prefix = "",
    root = "musa",
),
```

You can also use a published MUSA archive directly without editing metadata:

```bash
MUSA_DISTRO_URL=<release-url> \
MUSA_DISTRO_HASH=<sha256> \
MUSA_DISTRO_ROOT=musa \
bazel build //cc/tests/gpu/musa:vector_musa_build_test --config=musa
```

## Local Build

For oneAPI:

```bash
ACCEPT_INTEL_EULA=yes \
REPOSITORY=neudinger/rules-ml-toolchain-redists \
scripts/build_oneapi_redist.sh
```

For MUSA:

```bash
ACCEPT_MUSA_TERMS=yes \
VERSION=5.1.0 \
PACKAGE=musa_sdk_5_1_0_cc2_2_deb \
OS_ID=ubuntu \
ARCH=x86_64 \
MUSA_SOURCE_URL=<sdk-archive-url> \
MUSA_SOURCE_SHA256=<sdk-archive-sha256> \
REPOSITORY=neudinger/rules-ml-toolchain-redists \
scripts/build_musa_redist.sh
```

Set `ZSTD_LEVEL=1..22` to override the compression level.

## Local Dry Checks

These checks do not download the installer:

```bash
bash -n scripts/*.sh
ACCEPT_INTEL_EULA=no scripts/build_oneapi_redist.sh
ACCEPT_MUSA_TERMS=no scripts/build_musa_redist.sh
ACCEPT_MUSA_TERMS=yes VERSION=5.1.0 PACKAGE=musa_sdk_5_1_0_cc2_2_deb OS_ID=ubuntu scripts/build_musa_redist.sh
```

The dry-run commands should fail before download.

If `shellcheck` is installed, run:

```bash
shellcheck scripts/*.sh
```
