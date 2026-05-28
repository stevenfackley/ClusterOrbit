# Local Development

## Tooling

- Flutter stable SDK
- Dart SDK bundled with Flutter
- Xcode (macOS only) — required for iOS builds
- CocoaPods (macOS only) — `sudo gem install cocoapods` or `brew install cocoapods`
- Android Studio or Android SDK tools
- Go 1.24 or later for the gateway

## First commands

```powershell
cd app/mobile
Copy-Item .env.example .env
flutter pub get
flutter run

cd ../..
go test ./...
```

## iOS build (Mac only)

```bash
cd app/mobile
flutter pub get
cd ios && pod install && cd ..
flutter build ios --no-codesign        # compile smoke test, no signing required
flutter run -d "iPhone 15 Pro"         # simulator
```

Release builds for TestFlight run only in CI on the `clusterorbit-mac`
self-hosted runner — see `app/mobile/ios/README.md`.

## CI

Both Flutter and Go builds run locally and in CI. See `.github/workflows/`:

- `ci.yml` — mobile (format → analyze → test --coverage) + gateway (mod tidy → gofmt → vet → test -cover)
- `ios-release.yml` — IPA build + TestFlight upload on the self-hosted Mac runner
- `docs-check.yml` — markdownlint
