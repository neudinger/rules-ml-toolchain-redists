# rules-ml-toolchain-redists

This repository builds redistribution archives consumed by
`rules_ml_toolchain`.

The first supported artifact is a minimal Intel oneAPI 2026.0 archive for
Ubuntu 24.04 x86_64. The archive is produced from Intel's offline installer by a
manual GitHub Actions workflow. Intel installers and generated archives are not
checked into this repository.

## License

The scripts in this repository are licensed under Apache-2.0. Intel oneAPI and
the generated archive are subject to Intel's licenses. The workflow requires an
explicit EULA confirmation before it downloads or installs oneAPI, but that
confirmation is not a substitute for maintainer or legal approval to publish the
resulting archive.

## Build A Release

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

The archive is compressed with zstd at level 22 by default. GitHub release
assets must be smaller than 2 GB. The build fails if the archive is too large.
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

## Local Build

```bash
ACCEPT_INTEL_EULA=yes \
REPOSITORY=neudinger/rules-ml-toolchain-redists \
scripts/build_oneapi_redist.sh
```

Set `ZSTD_LEVEL=1..22` to override the compression level.

## Local Dry Checks

These checks do not download the installer:

```bash
bash -n scripts/*.sh
ACCEPT_INTEL_EULA=no scripts/build_oneapi_redist.sh
```

The second command should fail before download.

If `shellcheck` is installed, run:

```bash
shellcheck scripts/*.sh
```
