# Singapore Valhalla Configuration Reference

This document provides detailed explanations for all configuration parameters used in the Singapore-specific Valhalla setup.

## Table of Contents

- [Mjolnir Configuration](#mjolnir-configuration)
- [Loki Configuration](#loki-configuration)
- [Thor Configuration](#thor-configuration)
- [Meili Configuration](#meili-configuration)
- [Service Limits](#service-limits)

---

## Mjolnir Configuration

Mjolnir handles the routing graph tiles and tile operations.

### Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `tile_dir` | `data/valhalla_tiles/singapore` | Tile directory path - where routing graph tiles are stored |
| `max_cache_size` | `1073741824` (1GB) | Max tile cache size in bytes - sufficient for Singapore's 450MB tiles |
| `concurrency` | `4` | Parallel threads for tile operations - adjust based on CPU cores |

---

## Loki Configuration

Loki is the location service that handles coordinate snapping and API routing.

### Enabled Actions

| Action | Description |
|--------|-------------|
| `locate` | Snap GPS coordinates to nearest road |
| `route` | Calculate A-to-B routes |
| `sources_to_targets` | Matrix API for driver dispatch (1 pickup to N drivers) |
| `optimized_route` | TSP solver for multi-stop delivery optimization |
| `isochrone` | Calculate reachable area within time/distance |
| `trace_route` | Map-match GPS traces to roads |
| `status` | Health check endpoint |

### Service Defaults

| Parameter | Value | Description |
|-----------|-------|-------------|
| `minimum_reachability` | `50` | Min % of edge that must be reachable (50% = more flexible snapping for ride-hailing) |
| `radius` | `0` | Search radius in meters (0 = auto-calculate based on road density) |
| `search_cutoff` | `35000` | Max meters to search for nearest road (35km covers all of Singapore) |
| `node_snap_tolerance` | `5` | Max meters from intersection to snap (tight 5m for accuracy) |
| `street_side_tolerance` | `5` | Meters to prefer correct side of street (reduces U-turns at pickup/dropoff) |
| `street_side_max_distance` | `1000` | Max distance to enforce street side matching (1km) |
| `heading_tolerance` | `60` | Degrees of heading mismatch allowed (60° = flexible for GPS noise) |
| `mvt_min_zoom_road_class` | `[9, 10, 11, 11, 12, 12, 13, 13]` | Mapbox Vector Tiles zoom levels per road class (for map display) |
| `mvt_cache_min_zoom` | `0` | MVT tile cache minimum zoom level |
| `mvt_cache_max_zoom` | `15` | MVT tile cache maximum zoom level |

---

## Thor Configuration

Thor is the routing engine that calculates paths.

### Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `source_to_target_algorithm` | `select_optimal` | Auto-select best algorithm: A* for short routes, Dijkstra for long distances |
| `extended_search` | `false` | Disable extended search for faster matrix calculations in ride-hailing |

---

## Meili Configuration

Meili handles map-matching - aligning GPS traces to the road network.

### Mode

| Parameter | Value | Description |
|-----------|-------|-------------|
| `mode` | `auto` | Default map-matching mode |

### Customizable Parameters

The following parameters can be customized per request:
- `mode` - Routing mode (auto, bicycle, pedestrian)
- `search_radius` - Search radius for candidate roads
- `turn_penalty_factor` - Penalty for turns
- `gps_accuracy` - Expected GPS accuracy
- `interpolation_distance` - Distance between interpolated points
- `sigma_z` - GPS measurement noise
- `beta` - Exponential decay for route length preference
- `max_route_distance_factor` - Max route distance vs straight line
- `max_route_time_factor` - Max route time vs optimal

### Default Settings

| Parameter | Value | Description |
|-----------|-------|-------------|
| `sigma_z` | `4.07` | GPS measurement noise (4.07m std deviation - typical for smartphones) |
| `gps_accuracy` | `5.0` | Expected GPS accuracy in meters (5m for good signal) |
| `beta` | `3` | Exponential decay for route length preference (3 = moderate preference for shorter routes) |
| `max_route_distance_factor` | `5` | Max route distance factor vs straight line (5x = allows detours) |
| `max_route_time_factor` | `5` | Max route time factor vs optimal (5x = allows slower paths) |
| `breakage_distance` | `2000` | Distance to declare trace broken (2km gap = new trace) |
| `interpolation_distance` | `10` | Distance between interpolated points (10m = smooth trace) |
| `search_radius` | `50` | Search radius for candidate roads (50m for urban areas) |
| `geometry` | `false` | Return geometry in response |
| `route` | `true` | Return full route information |
| `turn_penalty_factor` | `200` | Penalty for turns (200 = prefer straight roads, important for ride-hailing accuracy) |

### Mode-Specific Settings

#### Auto (Cars/Taxis)
| Parameter | Value | Description |
|-----------|-------|-------------|
| `turn_penalty_factor` | `200` | High turn penalty for realistic routes |
| `search_radius` | `50` | 50m search radius |

#### Pedestrian
| Parameter | Value | Description |
|-----------|-------|-------------|
| `turn_penalty_factor` | `100` | Lower turn penalty (pedestrians can turn easily) |
| `search_radius` | `25` | 25m search radius |

#### Bicycle
| Parameter | Value | Description |
|-----------|-------|-------------|
| `turn_penalty_factor` | `140` | Moderate turn penalty |
| `search_radius` | `25` | 25m search radius |

### Grid Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `size` | `500` | Spatial grid cell size in meters (500m cells for coarse indexing) |
| `cache_size` | `100240` | Number of grid cells to cache (100240 cells = large area coverage) |

---

## Service Limits

Service limits control the maximum values for various API parameters.

### Auto (Cars)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_distance` | `5000000.0` | Max route distance in meters (5000km = covers all ride-hailing scenarios) |
| `max_locations` | `20` | Max waypoints per route (20 stops for multi-pickup) |
| `max_matrix_distance` | `400000.0` | Max matrix calculation distance (400km = cross-country in Singapore region) |
| `max_matrix_location_pairs` | `5000` | Max source-target pairs for matrix (5000 = 1 pickup × 5000 drivers) |

### Taxi

Same limits as auto for taxi/ride-hailing vehicles.

| Parameter | Value |
|-----------|-------|
| `max_distance` | `5000000.0` |
| `max_locations` | `20` |
| `max_matrix_distance` | `400000.0` |
| `max_matrix_location_pairs` | `5000` |

### Motorcycle

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_distance` | `500000.0` | Max route distance (500km = typical motorcycle range) |
| `max_locations` | `50` | More locations allowed (50 stops for food delivery) |
| `max_matrix_distance` | `200000.0` | Shorter matrix distance (200km for local delivery) |
| `max_matrix_location_pairs` | `2500` | Moderate matrix pairs (2500 = 1 pickup × 2500 riders) |

### Pedestrian

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_distance` | `250000.0` | Max walking distance (250km = unrealistic but allows flexibility) |
| `max_locations` | `50` | Many locations for walking tours |
| `max_matrix_distance` | `200000.0` | Matrix distance for pedestrian dispatch |
| `max_matrix_location_pairs` | `2500` | Matrix pairs |
| `min_transit_walking_distance` | `1` | Min walking distance to transit (1m) |
| `max_transit_walking_distance` | `10000` | Max walking distance to transit (10km) |

### Bicycle

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_distance` | `500000.0` | Max cycling distance (500km) |
| `max_locations` | `50` | Multiple stops for bike courier |
| `max_matrix_distance` | `200000.0` | Matrix for bike sharing dispatch |
| `max_matrix_location_pairs` | `2500` | Matrix pairs |

### Isochrone

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_contours` | `4` | Max time contours to calculate (4 = e.g., 5min, 10min, 15min, 20min) |
| `max_time_contour` | `120` | Max time contour in minutes (120min = 2 hour drive time) |
| `max_distance` | `200000.0` | Max distance for isochrone (200km) |
| `max_locations` | `1` | Only 1 location per isochrone request (center point) |
| `max_distance_contour` | `200` | Max distance contour in km (200km) |

### Trace

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_distance` | `200000.0` | Max trace route distance (200km for GPS trace matching) |
| `max_gps_accuracy` | `100.0` | Max allowed GPS accuracy in meters (100m = poor signal acceptable) |
| `max_search_radius` | `100.0` | Max search radius for trace matching (100m) |
| `max_shape` | `16000` | Max GPS points in trace (16000 points = ~4 hours at 1 point/sec) |
| `max_best_paths` | `4` | Max alternative paths to consider (4 alternatives) |
| `max_best_paths_shape` | `100` | Max points for best path alternatives (100 points) |
| `max_alternates` | `3` | Max alternate routes (3 alternatives) |
| `max_alternates_shape` | `100` | Max points for alternate routes (100 points) |

### Skadi (Elevation Service)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_shape` | `500000` | Max elevation query points (500k points) |
| `min_resample` | `10.0` | Min resample distance for elevation (10m) |

### General Limits

| Parameter | Value | Description |
|-----------|-------|-------------|
| `max_exclude_locations` | `50` | Max locations to exclude from routing |
| `max_reachability` | `100` | Max reachability percentage (100%) |
| `max_radius` | `200` | Max search radius in meters (200m) |
| `max_timedep_distance` | `500000` | Max distance for time-dependent routing (500km with traffic data) |
| `max_alternates` | `2` | Max alternate routes to return (2 alternates) |
| `max_exclude_polygons_length` | `10000` | Max polygon length for avoid areas (10000 points) |

---

## Costing Profiles

### Auto Costing

Singapore-specific auto costing with ERP (Electronic Road Pricing) and CBD awareness.

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maneuver_penalty` | `5` | Time penalty for maneuvers in seconds (5s for turns, lane changes) |
| `gate_cost` | `30` | Cost for passing gates like ERP gantries (30s penalty) |
| `toll_booth_cost` | `15` | Cost for toll booths (15s penalty - lower than gates for faster processing) |
| `use_highways` | `1.0` | Highway preference (1.0 = use highways, 0.0 = avoid, for Singapore: prefer expressways) |
| `use_tolls` | `1.0` | Toll preference (1.0 = use tolls/ERP, important for realistic Singapore routes) |
| `top_speed` | `90` | Max speed in km/h (90 = Singapore expressway limit) |
| `closure_factor` | `9.0` | Penalty factor for closed roads (9.0 = strongly avoid closures) |
| `shortest` | `false` | Route preference (false = fastest route, true = shortest distance) |

### Motorcycle Costing

Motorcycle costing with lane restrictions awareness.

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maneuver_penalty` | `5` | Time penalty for maneuvers (5s - motorcycles are more agile) |
| `use_highways` | `1.0` | Highway preference (1.0 = motorcycles allowed on Singapore expressways) |
| `use_tolls` | `1.0` | Toll preference (1.0 = motorcycles pay ERP in Singapore) |
| `top_speed` | `90` | Max speed in km/h (90 = same as cars on expressways) |

### Taxi Costing

Similar to auto costing with optimizations for professional drivers.

| Parameter | Value | Description |
|-----------|-------|-------------|
| `maneuver_penalty` | `5` | Time penalty for maneuvers (5s for professional drivers) |
| `use_highways` | `1.0` | Highway preference (1.0 = taxis use expressways) |
| `use_tolls` | `1.0` | Toll preference (1.0 = taxis pay ERP, factored into fare) |
| `top_speed` | `90` | Max speed (90 km/h - Singapore expressway limit) |
| `shortest` | `false` | Prefer fastest route for ride-hailing efficiency |

---

## Singapore Region Bounds

For location validation:

| Boundary | Value |
|----------|-------|
| `MIN_LAT` | `1.15` |
| `MAX_LAT` | `1.48` |
| `MIN_LON` | `103.6` |
| `MAX_LON` | `104.0` |

---

## Usage in Code

See `SingaporeConfig.kt` for programmatic access to these configurations:

```kotlin
// Build configuration
val config = SingaporeConfig.buildConfig(
    tileDir = "data/valhalla_tiles/singapore",
    enableTraffic = false
)

// Validate location
val isValid = SingaporeConfig.Bounds.isValidLocation(1.3521, 103.8198)

// Get costing profiles
val autoProfile = SingaporeConfig.Costing.autoProfile()
val motorcycleProfile = SingaporeConfig.Costing.motorcycleProfile()
val taxiProfile = SingaporeConfig.Costing.taxiProfile()
```
