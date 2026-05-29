# iOS

The Flutter iOS host project. Built and shipped to TestFlight from a self-hosted
Mac mini runner — see `.github/workflows/ios-release.yml`.

## Identity

| Field           | Value                       |
|-----------------|-----------------------------|
| Bundle ID       | `com.qavren.clusterorbit`   |
| Display name    | `ClusterOrbit`              |
| Min iOS         | per Flutter default         |
| Orientations    | portrait + landscape (phone), all four (iPad) |

Bundle ID is pinned in `Runner.xcodeproj/project.pbxproj` (six occurrences,
Debug/Release/Profile × Runner/RunnerTests). If you change it, update the App ID
in the Apple Developer Console and regenerate the provisioning profile.

## Local build

Requires macOS + Xcode + CocoaPods + Flutter.

```bash
cd app/mobile
flutter pub get
cd ios && pod install && cd ..
flutter build ios --no-codesign        # smoke test, no signing
flutter run -d "iPhone 15 Pro"         # simulator
```

## TestFlight build (CI only)

Triggered by `workflow_dispatch` or pushing a `v*` tag. Runs on the
`clusterorbit-mac` self-hosted runner.

The workflow:

1. Creates a throwaway keychain (deleted at end of run).
2. Imports the distribution `.p12` cert into that keychain.
3. Installs the provisioning profile into `~/Library/MobileDevice/Provisioning Profiles/`.
4. Generates `ExportOptions.plist` from the profile UUID + Team ID.
5. `flutter build ipa --release --build-number=${{ github.run_number }}`.
6. Uploads to App Store Connect via `xcrun altool` using an API key.
7. Cleans up keychain + profile.

### Required GitHub secrets

| Secret                              | What it is                                                                 |
|-------------------------------------|----------------------------------------------------------------------------|
| `APPLE_TEAM_ID`                     | 10-char Team ID from Apple Developer → Membership                          |
| `IOS_KEYCHAIN_PASSWORD`             | Any strong random string; only used to unlock the throwaway keychain       |
| `IOS_DIST_CERT_P12_BASE64`          | Distribution cert exported as `.p12`, then `base64 -i cert.p12`            |
| `IOS_DIST_CERT_P12_PASSWORD`        | Password you set when exporting the `.p12`                                 |
| `IOS_PROVISIONING_PROFILE_BASE64`   | `.mobileprovision` file, base64-encoded                                    |
| `APP_STORE_CONNECT_KEY_ID`          | Key ID shown in App Store Connect → Users and Access → Integrations → Keys |
| `APP_STORE_CONNECT_ISSUER_ID`       | Issuer ID shown on the same page                                           |
| `APP_STORE_CONNECT_KEY_P8_BASE64`   | The `.p8` file (downloadable once), base64-encoded                         |

Encode files for secrets with:

```bash
base64 -i AuthKey_ABC123.p8 | pbcopy
```

## Build numbers

`CFBundleVersion` is set per-build to `github.run_number`. This is monotonic and
unique across all workflow runs in the repo, which is what App Store Connect
requires per `CFBundleShortVersionString` (the marketing version in `pubspec.yaml`).

If you ever need to reset the marketing version, bump `version:` in
`app/mobile/pubspec.yaml` (left of the `+`). The right side of the `+` is
ignored by CI — `--build-number` overrides it.
