# Decisions

## 2026-08-19 — Dependabot sweep: gateway CI fix + flutter majors

**Status:** accepted (awareness-only stub per saved sweep policy)
**Decision:** fixed the base first, then merged the wave.

- **Root cause of the all-red PRs:** the reusable `ci-go.yml@v1` call passed no `go-version`, so govulncheck scanned a stale toolchain and exit-3'd on five Go stdlib CVEs on every PR — even docs-only ones. Fixed by passing `go-version: stable` (#19). If gateway CI reds again on stdlib vulns, the answer is a toolchain bump, never merging through it.
- **flutter_lints 4.0 → 6.0** (/app/mobile, #14): lint-only major; `flutter analyze` green post-fix. New lints may surface on future code — fix, don't pin back.
- **flutter_dotenv 5.2 → 6.0** (/app/mobile, #13): v6 tightens load/init API (`dotenv.load` signature + missing-file behaviour). Analyze+tests green; watch the env bootstrap on the next app run.
- markdownlint-cli2-action 24.1 → 24.2 (#17): routine.

**Why no review:** sweep policy — CI gates, revert cheap.

## 2026-09-22 — Dependabot sweep: Android build fix + Gradle 9 / AGP 9

**Status:** accepted (awareness-only stub per saved sweep policy)
**Decision:** fixed the Android build on main, added a CI lane for it, then landed the interlocked Gradle/AGP majors together.

- **Root cause:** KGP 2.2.20 → 2.4.20 (#23) turned `kotlinOptions.jvmTarget` into a hard error, which broke `flutter build apk` on main. CI stayed green because no job ran Gradle. Fixed by moving to `kotlin { compilerOptions }`, and a new `android` CI job (`flutter build apk --debug`) now covers app/mobile/android (#26).
- **Gradle wrapper 8.14 → 9.7.1 + AGP 8.11.1 → 9.4.1** (#27, replaces #25/#24): interlocked majors, because AGP 9 needs Gradle 9. KGP is still applied, with `android.builtInKotlin=false` / `android.newDsl=false` (the Flutter migrator's flags). Flutter warns that applying KGP will break in a future release, so migrating to built-in Kotlin is owed.

**Why no review:** sweep policy says CI gates the change and reverting is cheap. The Android lane now makes that true for Gradle bumps too.
