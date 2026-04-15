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
flutter pub get
flutter run

cd ../gateway
go test ./...
```

## Note

The current scaffold was written without local Flutter or Go SDKs installed. Validate generated platform files with those toolchains before shipping.
