# Valhalla JNI Bindings — Documentation

Java/Kotlin JNI bindings for the Valhalla routing engine.

| Doc | Read it for |
|-----|-------------|
| [setup/BUILD_AND_RUN.md](setup/BUILD_AND_RUN.md) | Building tiles, building the JNI library, configuring the tile path, running tests and benchmarks |
| [setup/INTEGRATION_GUIDE.md](setup/INTEGRATION_GUIDE.md) | Embedding the JAR in a service: `ActorPool` wiring, backpressure, timeouts, sizing, and per-use-case code snippets |
| [regions/ADDING_REGIONS.md](regions/ADDING_REGIONS.md) | Adding a new routing region to `config/regions/regions.json` and building its tiles |
| [CONFIGURATION.md](CONFIGURATION.md) | Valhalla config reference: mjolnir, loki, thor, meili, service limits, costing profiles |

`packages.md` is the Dokka module description consumed by `./gradlew dokkaHtml`;
it is not meant to be read directly.

## Start here

- **Integrating the library into a service** → `setup/INTEGRATION_GUIDE.md`.
  A single `Actor` is **not** thread-safe; use `ActorPool`.
- **Building from scratch / new machine** → `setup/BUILD_AND_RUN.md`.
- **Adding a region** → `regions/ADDING_REGIONS.md`.

## Paths

Docs live under `src/bindings/java/docs`, but `scripts/`, `config/`, `docker/`
and `deploy/` are at the **repository root**. Commands starting `./scripts/...`
run from the repo root; `./gradlew ...` runs from `src/bindings/java`.

The production tile pipeline is `deploy/scripts/run-tile-pipeline.sh` (SG) and
`run-tile-pipeline-us.sh` (US); the `scripts/regions/*.sh` scripts documented in
BUILD_AND_RUN are the local/dev path.
