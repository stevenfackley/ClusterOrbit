# Topology Engine

The topology engine is the product's core differentiator.

## Principles

- machine-first by default
- high frame-rate pan and zoom
- grouped views at scale
- no widget-per-node rendering strategy
- progressive detail based on zoom level

## Scene Model

Represent topology as nodes, edges, groups, overlays, and annotations. Scene updates should be incremental and based on data deltas rather than whole-scene rebuilds.

## Performance Targets

- smooth interactions on current phones
- tablet-first usability for larger clusters
- limited overdraw
- background computation for expensive regrouping and layout work
