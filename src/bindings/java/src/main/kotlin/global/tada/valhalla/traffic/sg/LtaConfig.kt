package global.tada.valhalla.traffic.sg

import org.slf4j.LoggerFactory

// LTA DataMall config — created via fromEnvironment()
data class LtaConfig(
    val accountKey: String,
    val baseUrl: String = DEFAULT_BASE_URL,
    val speedBandsPollMs: Long = DEFAULT_SPEED_BANDS_POLL_MS,
    val incidentsPollMs: Long = DEFAULT_INCIDENTS_POLL_MS,
    val estTravelTimePollMs: Long = DEFAULT_EST_TRAVEL_TIME_POLL_MS,
    val enabled: Boolean = true,
    val enableSpeedBands: Boolean = true,
    val enableIncidents: Boolean = true,
    val enableEstTravelTimes: Boolean = true,
    val maxRetries: Int = DEFAULT_MAX_RETRIES,
    val retryBackoffMs: Long = DEFAULT_RETRY_BACKOFF_MS,
    val connectionTimeoutMs: Int = DEFAULT_CONNECTION_TIMEOUT_MS,
    val readTimeoutMs: Int = DEFAULT_READ_TIMEOUT_MS,
    val snapshotEnabled: Boolean = true,
    val snapshotDir: String = DEFAULT_SNAPSHOT_DIR,
    val snapshotRetentionDays: Int = DEFAULT_SNAPSHOT_RETENTION_DAYS,
    val useTraffic: Boolean = true,
    val trafficStaleThresholdMinutes: Int = DEFAULT_TRAFFIC_STALE_THRESHOLD_MINUTES
) {
    init {
        require(accountKey.isNotBlank()) { "LTA AccountKey must not be blank" }
        require(speedBandsPollMs >= MIN_POLL_INTERVAL_MS) {
            "Speed Bands poll interval must be >= ${MIN_POLL_INTERVAL_MS}ms"
        }
        require(incidentsPollMs >= MIN_POLL_INTERVAL_MS) {
            "Incidents poll interval must be >= ${MIN_POLL_INTERVAL_MS}ms"
        }
        require(estTravelTimePollMs >= MIN_POLL_INTERVAL_MS) {
            "Est Travel Time poll interval must be >= ${MIN_POLL_INTERVAL_MS}ms"
        }
        require(snapshotRetentionDays in 1..30) {
            "Snapshot retention days must be between 1 and 30"
        }
        require(trafficStaleThresholdMinutes in 1..120) {
            "Traffic stale threshold must be between 1 and 120 minutes"
        }
    }

    companion object {
        private val logger = LoggerFactory.getLogger(LtaConfig::class.java)

        const val DEFAULT_BASE_URL = "https://datamall2.mytransport.sg/ltaodataservice"
        const val DEFAULT_SPEED_BANDS_POLL_MS = 300_000L      // 5 minutes
        const val DEFAULT_INCIDENTS_POLL_MS = 120_000L         // 2 minutes
        const val DEFAULT_EST_TRAVEL_TIME_POLL_MS = 300_000L   // 5 minutes
        const val DEFAULT_MAX_RETRIES = 3
        const val DEFAULT_RETRY_BACKOFF_MS = 2_000L
        const val DEFAULT_CONNECTION_TIMEOUT_MS = 10_000
        const val DEFAULT_READ_TIMEOUT_MS = 30_000
        const val MIN_POLL_INTERVAL_MS = 30_000L               // 30 seconds minimum
        // Fallback only — in production, snapshot_dir should come from mjolnir config
        // (derived from tile_dir via ../ pattern, same as traffic_extract and incident_dir)
        const val DEFAULT_SNAPSHOT_DIR = "data/lta_snapshots"
        const val DEFAULT_SNAPSHOT_RETENTION_DAYS = 7
        const val DEFAULT_TRAFFIC_STALE_THRESHOLD_MINUTES = 15

        // Environment variable names
        const val ENV_ACCOUNT_KEY = "LTA_ACCOUNT_KEY"
        const val ENV_BASE_URL = "LTA_BASE_URL"
        const val ENV_SPEED_BANDS_POLL_MS = "LTA_SPEED_BANDS_POLL_MS"
        const val ENV_INCIDENTS_POLL_MS = "LTA_INCIDENTS_POLL_MS"
        const val ENV_EST_TRAVEL_TIME_POLL_MS = "LTA_EST_TRAVEL_TIME_POLL_MS"
        const val ENV_ENABLED = "LTA_TRAFFIC_ENABLED"
        const val ENV_ENABLE_SPEED_BANDS = "LTA_ENABLE_SPEED_BANDS"
        const val ENV_ENABLE_INCIDENTS = "LTA_ENABLE_INCIDENTS"
        const val ENV_ENABLE_EST_TRAVEL_TIMES = "LTA_ENABLE_EST_TRAVEL_TIMES"
        const val ENV_SNAPSHOT_ENABLED = "LTA_SNAPSHOT_ENABLED"
        const val ENV_SNAPSHOT_DIR = "LTA_SNAPSHOT_DIR"
        const val ENV_SNAPSHOT_RETENTION_DAYS = "LTA_SNAPSHOT_RETENTION_DAYS"
        const val ENV_USE_TRAFFIC = "LTA_USE_TRAFFIC"
        const val ENV_TRAFFIC_STALE_THRESHOLD_MINUTES = "LTA_TRAFFIC_STALE_THRESHOLD_MINUTES"

        // Reads env vars first, falls back to system properties
        @JvmStatic
        fun fromEnvironment(): LtaConfig {
            val accountKey = System.getenv(ENV_ACCOUNT_KEY)
                ?: System.getProperty("lta.account.key")
                ?: throw IllegalArgumentException(
                    "LTA API key not configured. Set $ENV_ACCOUNT_KEY environment variable " +
                    "or lta.account.key system property."
                )

            val config = LtaConfig(
                accountKey = accountKey,
                baseUrl = System.getenv(ENV_BASE_URL)
                    ?: System.getProperty("lta.base.url")
                    ?: DEFAULT_BASE_URL,
                speedBandsPollMs = System.getenv(ENV_SPEED_BANDS_POLL_MS)
                    ?.toLongOrNull() ?: DEFAULT_SPEED_BANDS_POLL_MS,
                incidentsPollMs = System.getenv(ENV_INCIDENTS_POLL_MS)
                    ?.toLongOrNull() ?: DEFAULT_INCIDENTS_POLL_MS,
                estTravelTimePollMs = System.getenv(ENV_EST_TRAVEL_TIME_POLL_MS)
                    ?.toLongOrNull() ?: DEFAULT_EST_TRAVEL_TIME_POLL_MS,
                enabled = System.getenv(ENV_ENABLED)
                    ?.toBooleanStrictOrNull()
                    ?: System.getProperty("lta.traffic.enabled")
                        ?.toBooleanStrictOrNull()
                    ?: true,
                enableSpeedBands = System.getenv(ENV_ENABLE_SPEED_BANDS)
                    ?.toBooleanStrictOrNull() ?: true,
                enableIncidents = System.getenv(ENV_ENABLE_INCIDENTS)
                    ?.toBooleanStrictOrNull() ?: true,
                enableEstTravelTimes = System.getenv(ENV_ENABLE_EST_TRAVEL_TIMES)
                    ?.toBooleanStrictOrNull() ?: true,
                snapshotEnabled = System.getenv(ENV_SNAPSHOT_ENABLED)
                    ?.toBooleanStrictOrNull() ?: true,
                snapshotDir = System.getenv(ENV_SNAPSHOT_DIR)
                    ?: DEFAULT_SNAPSHOT_DIR,
                snapshotRetentionDays = System.getenv(ENV_SNAPSHOT_RETENTION_DAYS)
                    ?.toIntOrNull() ?: DEFAULT_SNAPSHOT_RETENTION_DAYS,
                useTraffic = System.getenv(ENV_USE_TRAFFIC)
                    ?.toBooleanStrictOrNull() ?: true,
                trafficStaleThresholdMinutes = System.getenv(ENV_TRAFFIC_STALE_THRESHOLD_MINUTES)
                    ?.toIntOrNull() ?: DEFAULT_TRAFFIC_STALE_THRESHOLD_MINUTES
            )

            logger.info(
                "LTA config loaded: baseUrl={}, speedBandsPoll={}ms, incidentsPoll={}ms, enabled={}, snapshots={}",
                config.baseUrl, config.speedBandsPollMs, config.incidentsPollMs, config.enabled, config.snapshotEnabled
            )

            return config
        }
    }
}
