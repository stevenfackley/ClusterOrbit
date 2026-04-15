# Product Vision

ClusterOrbit exists to make Kubernetes cluster state legible on mobile devices. The product centers on spatial understanding, machine health, and safe operator workflows rather than command-line feature parity for its own sake.

## Problem

Operators can already inspect clusters from desktops, terminals, and browser dashboards, but mobile experiences are usually:

- list-heavy
- weak at showing node and workload relationships
- poor on tablets
- too shallow for real administration or too dangerous for touch-first editing

## Promise

ClusterOrbit should let a power user open a phone or tablet and immediately answer:

- What machines are in trouble?
- What workloads are concentrated where?
- What changed recently?
- Can I inspect, validate, and safely change this config?

## Non-Goals

- A full replacement for every desktop Kubernetes dashboard.
- A thin wrapper around raw `kubectl`.
- A novelty 3D view that trades clarity for flair.
