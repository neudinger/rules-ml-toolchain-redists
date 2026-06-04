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

- `version`: MUSA SDK version. Default: `5.1.0`.
- `package`: matching `MUSA_REDIST` key from
  `rules_ml_toolchain/gpu/musa/musa_redist.bzl`. Default:
  `musa_sdk_5_1_0_cc3_1_deb`.
- `os_id`: target OS identifier. Default: `ubuntu`.
- `arch`: target architecture. Default: `x86_64`.
- `musa_device`: optional target MTT GPU family. Empty infers from
  `package`; examples: `S5000`, `S4000`, `S80`.
- `musa_source_kind`: source mode. Default: `apt`.
- `musa_apt_repository`: Moore Threads APT repository. Default:
  `https://dl.mthreads.com/repo/repository/ubuntu2204`.
- `musa_apt_distribution`: APT distribution. Default: `jammy`.
- `musa_apt_component`: APT component. Default: `main`.
- `musa_apt_binary_arch`: APT binary architecture. Default: `amd64`.
- `musa_apt_packages`: optional comma or space separated root package list.
  Empty uses package-aware defaults: `musa-toolkit-5-1`,
  `libmthreads-compute`, `libmudnn3-musa-5`, `libmudnn3-musa-5-dev`, plus
  `mccl-s5000` and `mccl-s5000-dev` for `cc3_1` package keys or
  `mccl-s4000` and `mccl-s4000-dev` for `cc2_2` package keys.
- `accept_musa_terms`: `true`.

APT mode downloads the repository `Packages.gz`, resolves the selected package
closure, verifies each `.deb` with the SHA256 published in that package index,
extracts with `dpkg-deb`, and normalizes the result into a top-level `musa/`
toolkit archive. Archive mode keeps the original behavior for full SDK archives
that are provided explicitly by maintainers.

Archive mode in GitHub Actions does not expose URL or hash workflow inputs.
Configure `MUSA_SOURCE_URL` as a repository secret or variable and
`MUSA_SOURCE_SHA256` as a repository variable before running an archive build.

MTT S80 support uses archive mode. The current public Moore Threads APT repo is
the MUSA 5.1 Ubuntu package source used for S5000/S4000 package keys, while the
official S80 download entry is `MUSA SDK rc3.1.1`. For S80/S3000 builds, the
script does not add MCCL packages because Moore Threads documents MCCL as not
provided for those architectures.

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
"musa_sdk_5_1_0_cc3_1_deb": _entry(
    "5.1.0",
    ["5.1.0"],
    ["MTT S5000"],
    ["Ubuntu"],
    "2051966049083068416",
    "MUSA_SDK_5.1.0.CC3.1.DEB",
    "deb",
    url = "https://github.com/<owner>/rules-ml-toolchain-redists/releases/download/musa-v5.1.0-musa_sdk_5_1_0_cc3_1_deb-ubuntu-x86_64/musa-toolkit-5.1.0-musa_sdk_5_1_0_cc3_1_deb-ubuntu-x86_64.tar.zst",
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
PACKAGE=musa_sdk_5_1_0_cc3_1_deb \
OS_ID=ubuntu \
ARCH=x86_64 \
MUSA_SOURCE_KIND=apt \
REPOSITORY=neudinger/rules-ml-toolchain-redists \
scripts/build_musa_redist.sh
```

To build from an explicitly provided SDK archive instead:

```bash
ACCEPT_MUSA_TERMS=yes \
VERSION=5.1.0 \
PACKAGE=musa_sdk_5_1_0_cc3_1_deb \
OS_ID=ubuntu \
ARCH=x86_64 \
MUSA_SOURCE_KIND=archive \
MUSA_SOURCE_URL=<sdk-archive-url> \
MUSA_SOURCE_SHA256=<sdk-archive-sha256> \
REPOSITORY=neudinger/rules-ml-toolchain-redists \
scripts/build_musa_redist.sh
```

For MTT S80, use an approved S80 SDK archive via the same local environment
variables, or set `MUSA_SOURCE_URL` and `MUSA_SOURCE_SHA256` as repository
secret/variable values for the workflow:

```bash
ACCEPT_MUSA_TERMS=yes \
VERSION=rc3.1.1 \
PACKAGE=musa_sdk_rc3_1_1 \
OS_ID=ubuntu \
ARCH=x86_64 \
MUSA_DEVICE=S80 \
MUSA_SOURCE_KIND=archive \
MUSA_SOURCE_URL=<s80-sdk-archive-url> \
MUSA_SOURCE_SHA256=<s80-sdk-archive-sha256> \
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
ACCEPT_MUSA_TERMS=yes VERSION=5.1.0 PACKAGE=musa_sdk_5_1_0_cc3_1_deb OS_ID=ubuntu MUSA_SOURCE_KIND=archive scripts/build_musa_redist.sh
```

The dry-run commands should fail before download.

If `shellcheck` is installed, run:

```bash
shellcheck scripts/*.sh
```
