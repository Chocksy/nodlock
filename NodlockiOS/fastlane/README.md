fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios metadata

```sh
[bundle exec] fastlane ios metadata
```

Upload App Store metadata, review notes and screenshots. No binary.

Run `fastlane precheck_local` first. Requires ASC_* env vars.

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build the app and upload it to TestFlight (internal testers only).

### ios release

```sh
[bundle exec] fastlane ios release
```

Build, upload the binary, upload metadata and submit for App Store review.

Release stays manual: automatic_release is false, so you press the button.

### ios precheck_local

```sh
[bundle exec] fastlane ios precheck_local
```

Offline metadata check. Verifies every required file exists and fits

Apple's character limits. Makes no network calls, needs no credentials.

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
