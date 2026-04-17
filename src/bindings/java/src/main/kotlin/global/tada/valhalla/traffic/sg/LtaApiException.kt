package global.tada.valhalla.traffic.sg

// Thrown on LTA API failures (bad status, timeout, malformed response)
class LtaApiException @JvmOverloads constructor(
    message: String,
    val statusCode: Int = 0,
    cause: Throwable? = null
) : RuntimeException(message, cause)
