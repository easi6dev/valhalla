package global.tada.valhalla.newyork

/**
 * Real NY tri-state (NY / NJ / CT) locations for ride-hailing testing.
 * All coordinates are verified and represent actual landmarks.
 *
 * The three states share the `nyc_tri_state` tile set, so the cross-state
 * routes below (NYC <-> Newark NJ, NYC <-> Stamford CT) are the headline case
 * the shared tile group exists to support.
 */
data class Location(
    val lat: Double,
    val lon: Double,
    val name: String,
    val area: String,
    val state: String
)

object NewYorkLocations {

    // --- New York ---
    val TIMES_SQUARE = Location(
        lat = 40.7580, lon = -73.9855, name = "Times Square", area = "Manhattan", state = "NY"
    )
    val JFK_AIRPORT = Location(
        lat = 40.6413, lon = -73.7781, name = "JFK Airport", area = "Queens", state = "NY"
    )
    val LAGUARDIA_AIRPORT = Location(
        lat = 40.7769, lon = -73.8740, name = "LaGuardia Airport", area = "Queens", state = "NY"
    )
    val BROOKLYN_BRIDGE = Location(
        lat = 40.7061, lon = -73.9969, name = "Brooklyn Bridge", area = "Brooklyn", state = "NY"
    )
    val YANKEE_STADIUM = Location(
        lat = 40.8296, lon = -73.9262, name = "Yankee Stadium", area = "Bronx", state = "NY"
    )
    val WALL_STREET = Location(
        lat = 40.7069, lon = -74.0113, name = "Wall Street", area = "Manhattan", state = "NY"
    )
    val CENTRAL_PARK = Location(
        lat = 40.7829, lon = -73.9654, name = "Central Park", area = "Manhattan", state = "NY"
    )

    // --- New Jersey ---
    val NEWARK_AIRPORT = Location(
        lat = 40.6895, lon = -74.1745, name = "Newark Liberty Airport", area = "Newark", state = "NJ"
    )
    val NEWARK_PENN = Location(
        lat = 40.7344, lon = -74.1644, name = "Newark Penn Station", area = "Newark", state = "NJ"
    )
    val JERSEY_CITY = Location(
        lat = 40.7178, lon = -74.0431, name = "Jersey City", area = "Hudson County", state = "NJ"
    )
    val HOBOKEN = Location(
        lat = 40.7439, lon = -74.0324, name = "Hoboken Terminal", area = "Hudson County", state = "NJ"
    )

    // --- Connecticut ---
    val STAMFORD = Location(
        lat = 41.0534, lon = -73.5387, name = "Stamford", area = "Fairfield County", state = "CT"
    )
    val HARTFORD = Location(
        lat = 41.7658, lon = -72.6734, name = "Hartford", area = "Hartford County", state = "CT"
    )
    val NEW_HAVEN = Location(
        lat = 41.3083, lon = -72.9279, name = "New Haven", area = "New Haven County", state = "CT"
    )
    val GREENWICH = Location(
        lat = 41.0262, lon = -73.6282, name = "Greenwich", area = "Fairfield County", state = "CT"
    )

    /**
     * All locations as a list for iteration / matrix tests.
     */
    val ALL_LOCATIONS = listOf(
        TIMES_SQUARE, JFK_AIRPORT, LAGUARDIA_AIRPORT, BROOKLYN_BRIDGE, YANKEE_STADIUM,
        WALL_STREET, CENTRAL_PARK,
        NEWARK_AIRPORT, NEWARK_PENN, JERSEY_CITY, HOBOKEN,
        STAMFORD, HARTFORD, NEW_HAVEN, GREENWICH
    )

    /**
     * Common test routes for ride-hailing scenarios.
     */
    object TestRoutes {
        // Short intra-NYC route (< 8 km)
        val SHORT_ROUTE = Pair(TIMES_SQUARE, WALL_STREET)

        // Medium intra-NYC route (Manhattan -> JFK)
        val MEDIUM_ROUTE = Pair(TIMES_SQUARE, JFK_AIRPORT)

        // Cross-state: NYC -> Newark NJ (the headline shared-tile case)
        val NYC_TO_NJ = Pair(TIMES_SQUARE, NEWARK_AIRPORT)

        // Cross-state: NYC -> Stamford CT
        val NYC_TO_CT = Pair(TIMES_SQUARE, STAMFORD)

        // Cross-state long haul: Newark NJ -> Hartford CT (traverses all three)
        val NJ_TO_CT = Pair(NEWARK_PENN, HARTFORD)
    }

    /**
     * Driver locations for matrix testing.
     */
    fun getDriverLocations(count: Int = 5): List<Location> = ALL_LOCATIONS.take(count)

    /**
     * Multi-waypoint locations for optimization testing.
     */
    fun getMultiWaypoints(): List<Location> = listOf(
        TIMES_SQUARE, CENTRAL_PARK, YANKEE_STADIUM, LAGUARDIA_AIRPORT, JFK_AIRPORT
    )
}
