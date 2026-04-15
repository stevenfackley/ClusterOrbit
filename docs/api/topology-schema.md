# Topology Schema

Each topology snapshot should contain:

- entities with stable identifiers
- relationship edges
- grouping metadata
- severity and health fields
- recent change markers
- render hints for color, icon, and grouping density

The schema should be optimized for fast scene hydration and delta updates rather than fully normalized transport.
