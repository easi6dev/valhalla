package global.tada.valhalla.config

import java.io.File

/**
 * Singapore-specific configuration helper for Valhalla Actor
 * Provides optimized settings for Singapore ride-hailing use cases
 *
 * For detailed parameter descriptions, see: docs/singapore/CONFIGURATION_REFERENCE.md
 */
object SingaporeConfig {

    /**
     * Create a Singapore-optimized configuration
     *
     * For detailed parameter descriptions, see: docs/singapore/CONFIGURATION_REFERENCE.md
     *
     * @param tileDir Path to Singapore tiles directory (default: data/valhalla_tiles/singapore)
     * @param enableTraffic Enable traffic-aware routing (default: false)
     * @return JSON configuration string
     */
    fun buildConfig(
        tileDir: String = "data/valhalla_tiles/singapore",
        enableTraffic: Boolean = false
    ): String {
        val resolvedTileDir = File(tileDir).canonicalPath.replace("\\", "/")

        return """
        {
          "mjolnir": {
            "tile_dir": "$resolvedTileDir",
            "max_cache_size": 1073741824,
            "concurrency": 4
          },
          "loki": {
            "actions": [
              "locate",
              "route",
              "sources_to_targets",
              "optimized_route",
              "isochrone",
              "trace_route",
              "status"
            ],
            "service_defaults": {
              "minimum_reachability": 50,
              "radius": 0,
              "search_cutoff": 35000,
              "node_snap_tolerance": 5,
              "street_side_tolerance": 5,
              "street_side_max_distance": 1000,
              "heading_tolerance": 60,
              "mvt_min_zoom_road_class": [9, 10, 11, 11, 12, 12, 13, 13],
              "mvt_cache_min_zoom": 0,
              "mvt_cache_max_zoom": 15
            }
          },
          "thor": {
            "source_to_target_algorithm": "select_optimal",
            "extended_search": false
          },
          "meili": {
            "mode": "auto",
            "customizable": ["mode", "search_radius", "turn_penalty_factor", "gps_accuracy", "interpolation_distance", "sigma_z", "beta", "max_route_distance_factor", "max_route_time_factor"],
            "default": {
              "sigma_z": 4.07,
              "gps_accuracy": 5.0,
              "beta": 3,
              "max_route_distance_factor": 5,
              "max_route_time_factor": 5,
              "breakage_distance": 2000,
              "interpolation_distance": 10,
              "search_radius": 50,
              "geometry": false,
              "route": true,
              "turn_penalty_factor": 200
            },
            "auto": {
              "turn_penalty_factor": 200,
              "search_radius": 50
            },
            "pedestrian": {
              "turn_penalty_factor": 100,
              "search_radius": 25
            },
            "bicycle": {
              "turn_penalty_factor": 140,
              "search_radius": 25
            },
            "grid": {
              "size": 500,
              "cache_size": 100240
            }
          },
          "service_limits": {
            "auto": {
              "max_distance": 5000000.0,
              "max_locations": 20,
              "max_matrix_distance": 400000.0,
              "max_matrix_location_pairs": 5000
            },
            "taxi": {
              "max_distance": 5000000.0,
              "max_locations": 20,
              "max_matrix_distance": 400000.0,
              "max_matrix_location_pairs": 5000
            },
            "motorcycle": {
              "max_distance": 500000.0,
              "max_locations": 50,
              "max_matrix_distance": 200000.0,
              "max_matrix_location_pairs": 2500
            },
            "pedestrian": {
              "max_distance": 250000.0,
              "max_locations": 50,
              "max_matrix_distance": 200000.0,
              "max_matrix_location_pairs": 2500,
              "min_transit_walking_distance": 1,
              "max_transit_walking_distance": 10000
            },
            "bicycle": {
              "max_distance": 500000.0,
              "max_locations": 50,
              "max_matrix_distance": 200000.0,
              "max_matrix_location_pairs": 2500
            },
            "isochrone": {
              "max_contours": 4,
              "max_time_contour": 120,
              "max_distance": 200000.0,
              "max_locations": 1,
              "max_distance_contour": 200
            },
            "trace": {
              "max_distance": 200000.0,
              "max_gps_accuracy": 100.0,
              "max_search_radius": 100.0,
              "max_shape": 16000,
              "max_best_paths": 4,
              "max_best_paths_shape": 100,
              "max_alternates": 3,
              "max_alternates_shape": 100
            },
            "skadi": {
              "max_shape": 500000,
              "min_resample": 10.0
            },
            "max_exclude_locations": 50,
            "max_reachability": 100,
            "max_radius": 200,
            "max_timedep_distance": 500000,
            "max_alternates": 2,
            "max_exclude_polygons_length": 10000,
            "status": {}
          }
        }
        """.trimIndent()
    }

    /**
     * Singapore region bounds for validation
     */
    object Bounds {
        const val MIN_LAT = 1.15
        const val MAX_LAT = 1.48
        const val MIN_LON = 103.6
        const val MAX_LON = 104.0

        fun isValidLocation(lat: Double, lon: Double): Boolean {
            return lat in MIN_LAT..MAX_LAT && lon in MIN_LON..MAX_LON
        }
    }

    /**
     * Singapore-specific costing options
     *
     * For detailed parameter descriptions, see: docs/singapore/CONFIGURATION_REFERENCE.md
     */
    object Costing {
        /**
         * Auto costing with ERP and CBD awareness
         */
        fun autoProfile() = """
        {
          "costing": "auto",
          "costing_options": {
            "auto": {
              "maneuver_penalty": 5,
              "gate_cost": 30,
              "toll_booth_cost": 15,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 90,
              "closure_factor": 9.0,
              "shortest": false
            }
          }
        }
        """.trimIndent()

        /**
         * Motorcycle costing with lane restrictions
         */
        fun motorcycleProfile() = """
        {
          "costing": "motorcycle",
          "costing_options": {
            "motorcycle": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 90
            }
          }
        }
        """.trimIndent()

        /**
         * Taxi costing (similar to auto with optimizations)
         */
        fun taxiProfile() = """
        {
          "costing": "auto",
          "costing_options": {
            "auto": {
              "maneuver_penalty": 5,
              "use_highways": 1.0,
              "use_tolls": 1.0,
              "top_speed": 90,
              "shortest": false
            }
          }
        }
        """.trimIndent()
    }

    /**
     * Utility to load configuration from file
     */
    fun loadFromFile(configFile: String = "config/singapore/valhalla-singapore.json"): String {
        val file = File(configFile)
        if (!file.exists()) {
            throw IllegalArgumentException("Config file not found: $configFile")
        }
        return file.readText()
    }
}
