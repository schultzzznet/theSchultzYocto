# SDK example app: `sdk-hello-schultz`

Proves the eSDK (`bitbake schultz-image-minimal -c populate_sdk_ext`) is a
genuinely usable, self-contained toolchain for building Linux applications
against this exact device — not just "should work in theory". See
[docs/yocto-concepts.md](../../docs/yocto-concepts.md#the-sdk--building-linux-apps-against-this-device)
for the full story and the proof this was actually run on the real Pi 3 B+.

## What this is

A trivial C program, deliberately dumb: it prints its own architecture,
hostname, PID and the current time. Correct output only happens if it was
compiled for `aarch64` and actually executed on the target — a host-arch
build wouldn't even run there.

## Build with the SDK (no Yocto checkout needed — this is the whole point)

```sh
# on the build host, or anywhere the eSDK installer has been copied to:
. /opt/schultz-sdk/*/environment-setup-*
make
```

`environment-setup-*` exports `CC`/`CXX`/`PKG_CONFIG_SYSROOT_DIR` etc. pointed
at the cross-toolchain and a sysroot that matches `schultz-image-minimal`
byte-for-byte — same libc, same library versions.

## Deploy + run on the device

```sh
scp sdk-hello-schultz root@192.168.1.226:/tmp/
ssh root@192.168.1.226 /tmp/sdk-hello-schultz
```

## The `devtool` workflow (the "ext" in eSDK)

The plain SDK only gives you the toolchain above. The **extensible** SDK adds
`devtool`, which can deploy straight to a running device over SSH without a
manual `scp`+`ssh`:

```sh
devtool add sdk-hello-schultz /path/to/this/dir
devtool build sdk-hello-schultz
devtool deploy-target sdk-hello-schultz root@192.168.1.226
ssh root@192.168.1.226 /usr/bin/sdk-hello-schultz
devtool undeploy-target sdk-hello-schultz root@192.168.1.226   # clean removal
```
