# ADR-0001: Flutter-First Client

## Status

Accepted

## Context

ClusterOrbit needs a high-performance mobile client with strong tablet support and a custom-rendered topology view. The project also values a unified codebase across iOS and Android.

## Decision

Start with Flutter as the primary mobile client technology.

## Alternatives Considered

- React Native with a native or Skia-heavy rendering path
- fully native iOS and Android apps

## Consequences

- better control over custom rendering and adaptive layouts
- fewer cross-platform code splits at the start
- some ecosystem work will be more custom than a typical React stack
