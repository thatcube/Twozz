fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### generate_project

```sh
[bundle exec] fastlane generate_project
```

Regenerate the Xcode project from project.yml via XcodeGen

### build

```sh
[bundle exec] fastlane build
```

Archive and export a signed App Store .ipa (no upload)

### beta

```sh
[bundle exec] fastlane beta
```

Build and upload a new build to TestFlight

### metadata

```sh
[bundle exec] fastlane metadata
```

Push App Store text metadata only (name, subtitle, description, keywords)

### release

```sh
[bundle exec] fastlane release
```

Build, upload to App Store, and push metadata

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
