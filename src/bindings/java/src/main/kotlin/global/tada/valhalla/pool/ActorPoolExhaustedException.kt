package global.tada.valhalla.pool

import global.tada.valhalla.ValhallaException

/**
 * Thrown when [ActorPool.withActor] / [ActorPool.borrow] cannot obtain a free
 * [global.tada.valhalla.Actor] within the requested timeout because every actor
 * in the pool is currently in use.
 *
 * This is intentionally a DISTINCT type from [ValhallaException] (which signals
 * a routing/engine failure) so the consumer can tell "the engine failed" apart
 * from "we are at capacity right now". The recommended consumer mapping is:
 *
 * ```
 * try {
 *     pool.withActor { actor -> actor.route(req) }
 * } catch (e: ActorPoolExhaustedException) {
 *     // backpressure — return HTTP 429 Too Many Requests + Retry-After
 * } catch (e: ValhallaException) {
 *     // genuine routing error — 4xx/5xx as appropriate
 * }
 * ```
 *
 * Converting capacity exhaustion into a fast, explicit failure (rather than an
 * unbounded wait, OOM, or native crash) is the backpressure mechanism that keeps
 * the service responsive under overload.
 */
class ActorPoolExhaustedException @JvmOverloads constructor(
    message: String,
    cause: Throwable? = null
) : ValhallaException(message, cause)
