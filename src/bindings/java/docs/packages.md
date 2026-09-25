# Module Valhalla JNI

Java/Kotlin JNI bindings for the Valhalla routing engine.

Entry points:

- [global.tada.valhalla.Actor] — a single native routing actor. **Not thread-safe**;
  one Actor serves one request at a time.
- [global.tada.valhalla.pool.ActorPool] — the supported way to serve concurrent
  traffic. Borrows an Actor per request and applies backpressure when exhausted.

# Package global.tada.valhalla

Core routing API. `Actor` wraps the native `valhalla::tyr::actor_t` and exposes
route, matrix, isochrone, map-matching and related actions. All actions take a
JSON request string and return a JSON response string (except `tile`, which
returns a `ByteArray`).

# Package global.tada.valhalla.pool

Concurrency primitives. `ActorPool` owns a fixed set of Actors and hands them out
via `withActor`/`supplyAsync`; `BorrowQueue` implements the fair borrow queue and
`ActorPoolExhaustedException` signals backpressure.

# Package global.tada.valhalla.config

Region configuration. `RegionConfigFactory` builds Valhalla config JSON from
`config/regions/regions.json`; `TileConfig` resolves the tile directory;
`RegionConfigValidator` validates region definitions.

# Package global.tada.valhalla.dispatch

`DriverSelection` ranks candidate drivers for a pickup using the matrix API.

# Package global.tada.valhalla.traffic

Traffic-aware routing: live speed overlays, geometry mapping between provider
segments and Valhalla edges, and traffic status file handling.

# Package global.tada.valhalla.metrics

`ValhallaMetrics` collects request counters, latency and pool gauges, and can
render them in Prometheus text format via `exportPrometheusMetrics()`.

# Package global.tada.valhalla.validation

`RouteSmokeCheckJob` runs post-tile-build smoke routes to validate a tile set.
