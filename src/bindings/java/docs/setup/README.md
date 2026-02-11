# Spring Boot Integration Example

This example shows how to integrate Valhalla JNI into a Spring Boot microservice.

## Quick Start

### 1. Add Dependency

**build.gradle.kts:**
```kotlin
dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("global.tada.valhalla:valhalla-jni:1.0.0-SNAPSHOT")
    implementation("org.json:json:20240303")
}
```

### 2. Configuration

**application.yml:**
```yaml
valhalla:
  tile-dir: /data/valhalla_tiles/singapore
  region: singapore

server:
  port: 8088

management:
  endpoints:
    web:
      exposure:
        include: health,metrics
```

### 3. Service Implementation

**RoutingService.kt:**
```kotlin
package com.tada.routing.service

import global.tada.valhalla.Actor
import org.springframework.beans.factory.annotation.Value
import org.springframework.stereotype.Service
import javax.annotation.PostConstruct
import javax.annotation.PreDestroy

@Service
class RoutingService(
    @Value("\${valhalla.tile-dir}") private val tileDir: String
) {
    private lateinit var actor: Actor

    @PostConstruct
    fun init() {
        actor = Actor.createSingapore(tileDir)
        println("Valhalla Actor initialized with tiles from: $tileDir")
    }

    fun calculateRoute(from: Location, to: Location, costing: String = "auto"): String {
        val request = """
        {
          "locations": [
            {"lat": ${from.lat}, "lon": ${from.lon}},
            {"lat": ${to.lat}, "lon": ${to.lon}}
          ],
          "costing": "$costing",
          "units": "kilometers"
        }
        """
        return actor.route(request)
    }

    fun calculateMatrix(source: Location, targets: List<Location>): String {
        val targetsJson = targets.joinToString(",") {
            """{"lat": ${it.lat}, "lon": ${it.lon}}"""
        }

        val request = """
        {
          "sources": [{"lat": ${source.lat}, "lon": ${source.lon}}],
          "targets": [$targetsJson],
          "costing": "auto"
        }
        """
        return actor.matrix(request)
    }

    fun calculateIsochrone(location: Location, minutes: Int): String {
        val request = """
        {
          "locations": [{"lat": ${location.lat}, "lon": ${location.lon}}],
          "costing": "auto",
          "contours": [{"time": $minutes}],
          "polygons": true
        }
        """
        return actor.isochrone(request)
    }

    @PreDestroy
    fun cleanup() {
        actor.close()
    }
}

data class Location(val lat: Double, val lon: Double)
```

### 4. REST Controller

**RoutingController.kt:**
```kotlin
package com.tada.routing.controller

import com.tada.routing.service.Location
import com.tada.routing.service.RoutingService
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.*

@RestController
@RequestMapping("/api/v1/routing")
class RoutingController(private val routingService: RoutingService) {

    @PostMapping("/route")
    fun calculateRoute(@RequestBody request: RouteRequest): ResponseEntity<String> {
        val result = routingService.calculateRoute(
            from = request.from,
            to = request.to,
            costing = request.costing ?: "auto"
        )
        return ResponseEntity.ok()
            .header("Content-Type", "application/json")
            .body(result)
    }

    @PostMapping("/matrix")
    fun calculateMatrix(@RequestBody request: MatrixRequest): ResponseEntity<String> {
        val result = routingService.calculateMatrix(
            source = request.source,
            targets = request.targets
        )
        return ResponseEntity.ok()
            .header("Content-Type", "application/json")
            .body(result)
    }

    @PostMapping("/isochrone")
    fun calculateIsochrone(@RequestBody request: IsochroneRequest): ResponseEntity<String> {
        val result = routingService.calculateIsochrone(
            location = request.location,
            minutes = request.minutes
        )
        return ResponseEntity.ok()
            .header("Content-Type", "application/json")
            .body(result)
    }
}

data class RouteRequest(
    val from: Location,
    val to: Location,
    val costing: String? = "auto"
)

data class MatrixRequest(
    val source: Location,
    val targets: List<Location>
)

data class IsochroneRequest(
    val location: Location,
    val minutes: Int
)
```

### 5. Health Check

**HealthController.kt:**
```kotlin
package com.tada.routing.controller

import global.tada.valhalla.Actor
import org.springframework.boot.actuate.health.Health
import org.springframework.boot.actuate.health.HealthIndicator
import org.springframework.stereotype.Component

@Component
class ValhallaHealthIndicator(private val actor: Actor) : HealthIndicator {

    override fun health(): Health {
        return try {
            val status = actor.status("{}")
            Health.up()
                .withDetail("valhalla", "operational")
                .withDetail("status", status)
                .build()
        } catch (e: Exception) {
            Health.down()
                .withDetail("valhalla", "unavailable")
                .withException(e)
                .build()
        }
    }
}
```

### 6. Run Locally

```bash
# Make sure native libraries are in LD_LIBRARY_PATH
export LD_LIBRARY_PATH=/path/to/valhalla/build/src:/path/to/valhalla/build/src/bindings/java/libs/native:$LD_LIBRARY_PATH

# Run the application
./gradlew bootRun
```

### 7. Test the API

```bash
# Calculate route
curl -X POST http://localhost:8088/api/v1/routing/route \
  -H "Content-Type: application/json" \
  -d '{
    "from": {"lat": 1.2820, "lon": 103.8509},
    "to": {"lat": 1.3521, "lon": 103.8198}
  }'

# Calculate driver matrix
curl -X POST http://localhost:8088/api/v1/routing/matrix \
  -H "Content-Type: application/json" \
  -d '{
    "source": {"lat": 1.3048, "lon": 103.8318},
    "targets": [
      {"lat": 1.3000, "lon": 103.8300},
      {"lat": 1.3100, "lon": 103.8350},
      {"lat": 1.3020, "lon": 103.8280}
    ]
  }'

# Calculate isochrone
curl -X POST http://localhost:8088/api/v1/routing/isochrone \
  -H "Content-Type: application/json" \
  -d '{
    "location": {"lat": 1.2820, "lon": 103.8509},
    "minutes": 15
  }'

# Health check
curl http://localhost:8088/actuator/health
```

## Docker Deployment

**Dockerfile:**

```dockerfile
FROM gradle:8.5-jdk17 AS builder
WORKDIR /app
COPY ../../../../../examples/spring-boot-integration .
RUN gradle build -x test

FROM openjdk:17-slim

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    libboost-system1.74.0 \
    libboost-filesystem1.74.0 \
    libcurl4 \
    libprotobuf23 \
    libsqlite3-0 \
    liblz4-1 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Copy native libraries
COPY --from=valhalla-builder /valhalla/build/src/libvalhalla.so* /usr/local/lib/
COPY --from=valhalla-builder /valhalla/build/src/bindings/java/libs/native/libvalhalla_jni.so /usr/local/lib/
RUN ldconfig

# Copy application
COPY --from=builder /app/build/libs/*.jar /app/app.jar

# Copy tile data
COPY data/valhalla_tiles/singapore /data/valhalla_tiles/singapore

WORKDIR /app
EXPOSE 8088

ENV JAVA_OPTS="-Xmx2g"
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
```

**docker-compose.yml:**
```yaml
version: '3.8'

services:
  routing-service:
    build: .
    ports:
      - "8088:8088"
    volumes:
      - ./data/valhalla_tiles:/data/valhalla_tiles:ro
    environment:
      - SPRING_PROFILES_ACTIVE=production
      - VALHALLA_TILE_DIR=/data/valhalla_tiles/singapore
      - JAVA_OPTS=-Xmx2g
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8088/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
```

## Performance Tips

1. **Reuse Actor Instance**: Create one `Actor` instance per service (singleton pattern)
2. **Memory**: Allocate at least 2GB heap for JVM (`-Xmx2g`)
3. **Threads**: The Actor is thread-safe; you can call it concurrently
4. **Caching**: Consider caching frequently requested routes in Redis
5. **Monitoring**: Enable Spring Boot Actuator metrics

## Production Considerations

- Set up proper logging with structured logs
- Add request/response logging middleware
- Implement rate limiting
- Add authentication/authorization
- Set up monitoring and alerting
- Use connection pooling for database (if storing routes)
- Consider adding a CDN for tile data if serving multiple regions
