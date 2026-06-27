# Changelog

Release history for the `global.tada:valhalla-jni` JAR.

The JAR ships as snapshots: every CI publish produces a mutable `1.0.0-SNAPSHOT`
plus an immutable date version `YYYY.M.D.<run>` (the `2026.+` consumers resolve).
Add a row whenever a publish carries a consumer-visible change, using that build's
date version (shown in the "Publish JNI JAR" workflow summary). Newest on top;
routine rebuilds with no behavior change don't need a row.

| VERSION        | SUMMARY                                                                                                                                                                                  |
|----------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1.0.0-SNAPSHOT | Initial `valhalla-jni` bindings: route, matrix, isochrone, map-matching; sync, CompletableFuture, and coroutine APIs; AutoCloseable resource management; Java 17; native libs bundled for `linux-amd64`. |
