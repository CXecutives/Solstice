# Solstice

macOS on iPhone and iPad: a lean, performance-first macOS loader.

Solstice runs real macOS Sequoia 15.6.1 as an app, through its own arm64-to-arm64 JIT with its own MMU and devices, and
replays the Mac's GPU commands with Metal. No jailbreak. It downloads Apple's restore image and installs it on the device.

Solstice is based on [Henge](https://github.com/Leviidev/Henge) by Leviidev (GPL-2.0-or-later). It keeps Henge's engine
and narrows the scope to one job done well: start one Mac fast, keep it smooth, and stay small. See `NOTICE` for what changed.

## Status

A personal project, built for an iPhone 16 Pro and an iPad Air (4th generation). It targets devices with an A14 or newer
and iOS/iPadOS 26 or later, and macOS Sequoia 15.6.1 as the guest. There are no releases and no support.

## Build

Builds and tests run on GitHub Actions (`.github/workflows/build-henge.yml`), on a macOS runner:

- `tools/check.sh test_jit test_mem` runs the named engine tests for what a change touched.
- `tools/check-all.sh` runs every engine test (plain, with the shipped settings and ThinLTO, with undefined-behaviour
  traps), the register-safety gate, and builds the IPA.

## Install

Sideload the IPA with a tool that keeps the `increased-memory-limit` entitlement. JIT comes from the built-in helper
through LocalDevVPN; Solstice walks through pairing on the device.

Using macOS is subject to Apple's licence terms; that is the user's responsibility.

## Licence

GPL-2.0-or-later, see `LICENSE`, `NOTICE` and `docs/licensing.md`.
