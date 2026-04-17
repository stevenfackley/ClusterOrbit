# Local Development

## Planned Tooling

- Flutter stable SDK
- Dart SDK bundled with Flutter
- Xcode for iOS builds
- Android Studio or Android SDK tools
- Go 1.24 or later for the gateway

## First Commands

```powershell
cd app/mobile
Copy-Item .env.example .env
flutter pub get
flutter run

cd ../..
go test ./...
```

## Note

Both Flutter and Go builds run locally and in CI. See `.github/workflows/ci.yml` for the authoritative check set (mobile: format → analyze → test --coverage; gateway: mod tidy → gofmt → vet → test -cover).
