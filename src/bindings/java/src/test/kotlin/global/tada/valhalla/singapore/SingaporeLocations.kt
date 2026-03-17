package global.tada.valhalla.singapore

/**
 * Real Singapore locations for ride-hailing testing
 * All coordinates are verified and represent actual landmarks
 */
data class Location(
    val lat: Double,
    val lon: Double,
    val name: String,
    val area: String
)

object SingaporeLocations {

    val MARINA_BAY_SANDS = Location(
        lat = 1.2834,
        lon = 103.8607,
        name = "Marina Bay Sands",
        area = "Downtown"
    )

    val CHANGI_AIRPORT = Location(
        lat = 1.3644,
        lon = 103.9915,
        name = "Changi Airport",
        area = "East"
    )

    val ORCHARD_ROAD = Location(
        lat = 1.3048,
        lon = 103.8318,
        name = "Orchard Road",
        area = "Central"
    )

    val RAFFLES_PLACE = Location(
        lat = 1.2897,
        lon = 103.8501,
        name = "Raffles Place",
        area = "CBD"
    )

    val SENTOSA = Location(
        lat = 1.2494,
        lon = 103.8303,
        name = "Sentosa",
        area = "South"
    )

    val GARDENS_BY_THE_BAY = Location(
        lat = 1.2816,
        lon = 103.8636,
        name = "Gardens by the Bay",
        area = "Downtown"
    )

    val SINGAPORE_ZOO = Location(
        lat = 1.4043,
        lon = 103.7930,
        name = "Singapore Zoo",
        area = "North"
    )

    val JURONG_EAST = Location(
        lat = 1.3329,
        lon = 103.7436,
        name = "Jurong East",
        area = "West"
    )

    val WOODLANDS = Location(
        lat = 1.4382,
        lon = 103.7891,
        name = "Woodlands",
        area = "North"
    )

    val TAMPINES = Location(
        lat = 1.3496,
        lon = 103.9568,
        name = "Tampines",
        area = "East"
    )

    val CITY_HALL = Location(
        lat = 1.2930,
        lon = 103.8558,
        name = "City Hall",
        area = "CBD"
    )

    val CLARKE_QUAY = Location(
        lat = 1.2897,
        lon = 103.8467,
        name = "Clarke Quay",
        area = "CBD"
    )

    val BUGIS = Location(
        lat = 1.3005,
        lon = 103.8557,
        name = "Bugis",
        area = "Central"
    )

    /**
     * All locations as a list for iteration
     */
    val ALL_LOCATIONS = listOf(
        MARINA_BAY_SANDS,
        CHANGI_AIRPORT,
        ORCHARD_ROAD,
        RAFFLES_PLACE,
        SENTOSA,
        GARDENS_BY_THE_BAY,
        SINGAPORE_ZOO,
        JURONG_EAST,
        WOODLANDS,
        TAMPINES,
        CITY_HALL,
        CLARKE_QUAY,
        BUGIS
    )

    /**
     * Common test routes for ride-hailing scenarios
     */
    object TestRoutes {
        // Short routes (< 5km)
        val SHORT_ROUTE = Pair(RAFFLES_PLACE, MARINA_BAY_SANDS)

        // Medium routes (5-15km)
        val MEDIUM_ROUTE = Pair(ORCHARD_ROAD, CHANGI_AIRPORT)

        // Long routes (> 15km)
        val LONG_ROUTE = Pair(SINGAPORE_ZOO, SENTOSA)

        // Expressway route
        val EXPRESSWAY_ROUTE = Pair(JURONG_EAST, CHANGI_AIRPORT)

        // CBD route
        val CBD_ROUTE = Pair(RAFFLES_PLACE, CITY_HALL)

        // Cross-island route
        val CROSS_ISLAND = Pair(WOODLANDS, SENTOSA)
    }

    /**
     * Driver locations for matrix testing
     */
    fun getDriverLocations(count: Int = 5): List<Location> {
        return ALL_LOCATIONS.take(count)
    }

    /**
     * Multi-waypoint locations for optimization testing
     */
    fun getMultiWaypoints(): List<Location> {
        return listOf(
            ORCHARD_ROAD,
            BUGIS,
            RAFFLES_PLACE,
            MARINA_BAY_SANDS,
            GARDENS_BY_THE_BAY
        )
    }
}
