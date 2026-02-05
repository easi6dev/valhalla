package global.tada.valhalla

/**
 * Exception thrown by Valhalla routing engine operations.
 *
 * @property message Exception message
 * @property cause Optional underlying cause
 */
class ValhallaException @JvmOverloads constructor(
    message: String,
    cause: Throwable? = null
) : RuntimeException(message, cause)
