# Multi-stage build for Valhalla routing service
FROM gradle:8-jdk17 AS builder

WORKDIR /app

# Copy Valhalla JNI project
COPY ../../src/bindings/java ./valhalla-jni
COPY SimpleRoutingService.kt ./

# Build Valhalla JNI
WORKDIR /app/valhalla-jni
RUN gradle clean build publishToMavenLocal -x buildNative -x test

# Build service
WORKDIR /app
COPY build.gradle.kts ./
RUN gradle clean build -x test

# Runtime stage
FROM eclipse-temurin:17-jre-alpine

WORKDIR /app

# Copy built JAR
COPY --from=builder /app/build/libs/*.jar /app/routing-service.jar

# Tiles will be mounted at runtime
ENV VALHALLA_TILES_DIR=/tiles

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD java -cp /app/routing-service.jar HealthCheck || exit 1

ENTRYPOINT ["java", "-jar", "/app/routing-service.jar"]
