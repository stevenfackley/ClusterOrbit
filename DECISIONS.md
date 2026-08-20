# Decisions

## 2026-08-19 — Dependabot sweep: gateway CI fix + flutter majors

**Status:** accepted (awareness-only stub per saved sweep policy)
**Decision:** fixed the base first, then merged the wave.

- **Root cause of the all-red PRs:** the reusable `ci-go.yml@v1` call passed no `go-version`, so govulncheck scanned a stale toolchain and exit-3'd on five Go stdlib CVEs on every PR — even docs-only ones. Fixed by passing `go-version: stable` (#19). If gateway CI reds again on stdlib vulns, the answer is a toolchain bump, never merging through it.
- **flutter_lints 4.0 → 6.0** (/app/mobile, #14): lint-only major; `flutter analyze` green post-fix. New lints may surface on future code — fix, don't pin back.
- **flutter_dotenv 5.2 → 6.0** (/app/mobile, #13): v6 tightens load/init API (`dotenv.load` signature + missing-file behaviour). Analyze+tests green; watch the env bootstrap on the next app run.
- markdownlint-cli2-action 24.1 → 24.2 (#17): routine.

**Why no review:** sweep policy — CI gates, revert cheap.
