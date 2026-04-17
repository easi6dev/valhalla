package global.tada.valhalla.traffic.sg

import global.tada.valhalla.traffic.models.EstTravelTimeEntry
import global.tada.valhalla.traffic.models.SpeedBandEntry
import global.tada.valhalla.traffic.models.TrafficIncident
import org.json.JSONObject
import org.slf4j.LoggerFactory
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration

// HTTP client for LTA DataMall — handles pagination ($skip), retries, and JSON parsing
class LtaApiClient(private val config: LtaConfig) {

    private val logger = LoggerFactory.getLogger(LtaApiClient::class.java)

    private val httpClient: HttpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofMillis(config.connectionTimeoutMs.toLong()))
        .build()

    fun fetchSpeedBands(): List<SpeedBandEntry> {
        return fetchAllPages(ENDPOINT_SPEED_BANDS) { json ->
            SpeedBandEntry.fromJson(json)
        }
    }

    fun fetchSpeedBands(rawPageCollector: MutableList<String>): List<SpeedBandEntry> {
        return fetchAllPages(ENDPOINT_SPEED_BANDS, rawPageCollector) { json ->
            SpeedBandEntry.fromJson(json)
        }
    }

    fun fetchIncidents(): List<TrafficIncident> {
        return fetchAllPages(ENDPOINT_INCIDENTS) { json ->
            TrafficIncident.fromJson(json)
        }
    }

    fun fetchIncidents(rawPageCollector: MutableList<String>): List<TrafficIncident> {
        return fetchAllPages(ENDPOINT_INCIDENTS, rawPageCollector) { json ->
            TrafficIncident.fromJson(json)
        }
    }

    fun fetchEstTravelTimes(): List<EstTravelTimeEntry> {
        return fetchAllPages(ENDPOINT_EST_TRAVEL_TIMES) { json ->
            EstTravelTimeEntry.fromJson(json)
        }
    }

    fun fetchEstTravelTimes(rawPageCollector: MutableList<String>): List<EstTravelTimeEntry> {
        return fetchAllPages(ENDPOINT_EST_TRAVEL_TIMES, rawPageCollector) { json ->
            EstTravelTimeEntry.fromJson(json)
        }
    }

    // Paginate until fewer than PAGE_SIZE results come back
    private fun <T> fetchAllPages(
        endpoint: String,
        rawPageCollector: MutableList<String>? = null,
        parser: (JSONObject) -> T
    ): List<T> {
        val allResults = mutableListOf<T>()
        var skip = 0

        while (true) {
            val url = buildUrl(endpoint, skip)
            val responseBody = executeWithRetry(url)
            rawPageCollector?.add(responseBody)
            val json = JSONObject(responseBody)
            val valueArray = json.getJSONArray("value")

            for (i in 0 until valueArray.length()) {
                try {
                    allResults.add(parser(valueArray.getJSONObject(i)))
                } catch (e: Exception) {
                    logger.warn("Failed to parse entry at index {} from {}: {}",
                        i, endpoint, e.message)
                }
            }

            // If fewer than PAGE_SIZE results, we've reached the last page
            if (valueArray.length() < PAGE_SIZE) {
                break
            }

            skip += PAGE_SIZE
        }

        logger.debug("Fetched {} entries from {}", allResults.size, endpoint)
        return allResults
    }

    private fun buildUrl(endpoint: String, skip: Int): String {
        val base = "${config.baseUrl}/$endpoint"
        return if (skip > 0) "$base?\$skip=$skip" else base
    }

    // Retry with exponential backoff; throws LtaApiException after exhausting attempts
    private fun executeWithRetry(url: String): String {
        var lastException: Exception? = null

        for (attempt in 0..config.maxRetries) {
            try {
                if (attempt > 0) {
                    val delayMs = config.retryBackoffMs * (1L shl (attempt - 1))
                    logger.debug("Retry attempt {} for {} (delay: {}ms)", attempt, url, delayMs)
                    Thread.sleep(delayMs)
                }

                val request = HttpRequest.newBuilder()
                    .uri(URI.create(url))
                    .header("AccountKey", config.accountKey)
                    .header("Accept", "application/json")
                    .timeout(Duration.ofMillis(config.readTimeoutMs.toLong()))
                    .GET()
                    .build()

                val response = httpClient.send(request, HttpResponse.BodyHandlers.ofString())

                if (response.statusCode() == 200) {
                    return response.body()
                }

                // Non-retryable status codes
                if (response.statusCode() == 401 || response.statusCode() == 403) {
                    throw LtaApiException(
                        "Authentication failed (HTTP ${response.statusCode()}). " +
                        "Check your LTA AccountKey.",
                        response.statusCode()
                    )
                }

                lastException = LtaApiException(
                    "HTTP ${response.statusCode()} from $url: ${response.body().take(200)}",
                    response.statusCode()
                )
                logger.warn("LTA API returned HTTP {} for {}", response.statusCode(), url)

            } catch (e: LtaApiException) {
                // Don't retry auth errors
                if (e.statusCode in listOf(401, 403)) throw e
                lastException = e
            } catch (e: Exception) {
                lastException = e
                logger.warn("LTA API request failed for {}: {}", url, e.message)
            }
        }

        throw LtaApiException(
            "LTA API request failed after ${config.maxRetries + 1} attempts for $url: " +
            "${lastException?.message}",
            cause = lastException
        )
    }

    companion object {
        const val ENDPOINT_SPEED_BANDS = "v4/TrafficSpeedBands"
        const val ENDPOINT_INCIDENTS = "TrafficIncidents"
        const val ENDPOINT_EST_TRAVEL_TIMES = "EstTravelTimes"
        const val PAGE_SIZE = 500
    }
}
