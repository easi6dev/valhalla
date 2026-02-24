# Valhalla JNI - Testing & Monitoring Guide

Complete guide for testing and monitoring Valhalla JNI bindings in development, staging, and production environments.

**Date**: February 23, 2026
**Phase**: Phase 5 - Testing & Monitoring
**Status**: Production-Ready

---

## 📋 Table of Contents

1. [Testing Strategy](#testing-strategy)
2. [Performance Benchmarking](#performance-benchmarking)
3. [Load Testing](#load-testing)
4. [Integration Testing](#integration-testing)
5. [Monitoring Setup](#monitoring-setup)
6. [Metrics Collection](#metrics-collection)
7. [Alerting](#alerting)
8. [Troubleshooting](#troubleshooting)

---

## 🧪 Testing Strategy

### Test Pyramid

```
       ┌─────────────┐
       │   E2E Tests │  10%
       └─────────────┘
     ┌───────────────────┐
     │ Integration Tests │  20%
     └───────────────────┘
   ┌───────────────────────┐
   │     Unit Tests        │  70%
   └───────────────────────┘
```

### Test Categories

#### 1. Unit Tests (70%)
**Location**: `src/test/kotlin/`
**Focus**: Individual components, functions, classes

**Run**:
```bash
./gradlew test
```

**Coverage Target**: ≥ 80%

#### 2. Integration Tests (20%)
**Location**: `src/test/kotlin/global/tada/valhalla/IntegrationTest.kt`
**Focus**: End-to-end workflows, multi-component interactions

**Run**:
```bash
./gradlew test --tests '*IntegrationTest'
```

**Tests**:
- End-to-end routing workflow
- Multi-region support
- Configuration validation
- Error handling
- Resource cleanup
- Different costing options
- Long-running stability

#### 3. Load Tests (10%)
**Location**: `src/test/kotlin/global/tada/valhalla/LoadTest.kt`
**Focus**: Performance under load, scalability, stability

**Run**:
```bash
./gradlew test --tests '*LoadTest'
# Or use script
./scripts/load-test.sh all
```

**Tests**:
- High throughput (1000 routes)
- Concurrent load (100 threads)
- Sustained load (1 minute continuous)
- Memory stability
- Error handling under stress

---

## ⚡ Performance Benchmarking

### JMH Benchmarks

**Location**: `src/test/kotlin/global/tada/valhalla/performance/RouteBenchmark.kt`

**Benchmarks**:
1. **Simple Route** (2 points) - Target: 15ms
2. **Medium Route** (3 points) - Target: 25ms
3. **Complex Route** (5 waypoints) - Target: 50ms
4. **Concurrent Routing** (8 threads) - Target: 400 routes/sec
5. **Actor Initialization** - Target: 150ms

### Running Benchmarks

```bash
# All benchmarks
./gradlew jmh

# Specific benchmark
./scripts/run-benchmarks.sh simple

# Available options
./scripts/run-benchmarks.sh [simple|medium|complex|concurrent|initialization|all]
```

### Benchmark Results

**Expected Performance** (Singapore region):

| Benchmark | Target | Acceptable | Critical |
|-----------|--------|-----------|----------|
| Simple Route | 15ms | < 20ms | > 50ms |
| Medium Route | 25ms | < 35ms | > 80ms |
| Complex Route | 50ms | < 80ms | > 150ms |
| Concurrent Throughput | 500 routes/sec | > 400 routes/sec | < 200 routes/sec |
| Actor Init | 150ms | < 250ms | > 500ms |

### Analyzing Results

```bash
# View results
cat build/reports/jmh/results.json

# Extract key metrics (requires jq)
jq '.[] | {benchmark, score: .primaryMetric.score, unit: .primaryMetric.scoreUnit}' \
  build/reports/jmh/results.json
```

---

## 🔥 Load Testing

### Quick Load Test

```bash
./scripts/load-test.sh quick
```

**Profile**:
- 1000 sequential routes
- Duration: ~20 seconds
- Target throughput: > 40 routes/sec

### Concurrent Load Test

```bash
./scripts/load-test.sh concurrent
```

**Profile**:
- 100 concurrent threads
- 10 routes per thread
- Total: 1000 routes
- Target throughput: > 300 routes/sec
- Success rate: > 99%

### Sustained Load Test

```bash
./scripts/load-test.sh sustained
```

**Profile**:
- Duration: 1 minute continuous
- Target throughput: > 40 routes/sec
- Success rate: > 99%
- Memory stability: < 50% growth

### Memory Stability Test

```bash
./scripts/load-test.sh memory
```

**Profile**:
- Warmup: 100 routes
- Test: 500 routes
- Check: Memory growth < 50%

### Full Load Test Suite

```bash
./scripts/load-test.sh all
```

**Profile**:
- All load tests executed sequentially
- Comprehensive report generated
- Duration: ~10 minutes

### Load Test Reports

**Location**: `build/reports/load-tests/`

**Files**:
- `quick-load.log` - Quick test logs
- `concurrent-load.log` - Concurrent test logs
- `sustained-load.log` - Sustained test logs
- `memory-stability.log` - Memory test logs

**HTML Report**: `build/reports/tests/test/index.html`

---

## 🔗 Integration Testing

### Test Scenarios

#### Scenario 1: End-to-End Routing
```kotlin
@Test
fun testEndToEndRoutingWorkflow() {
    // 1. Validate configuration
    val validation = RegionConfigValidator.validate("config/regions/regions-dev.json")
    assertFalse(validation.hasErrors())

    // 2. Initialize actor
    val actor = Actor.createWithExternalTiles("singapore")

    // 3. Create request
    val request = RouteRequest(
        locations = listOf(
            RouteRequest.Location(1.290270, 103.851959),
            RouteRequest.Location(1.352083, 103.819836)
        ),
        costing = "auto"
    )

    // 4. Calculate route
    val response = actor.route(request)
    assertNotNull(response)

    // 5. Cleanup
    actor.close()
}
```

#### Scenario 2: Multi-Region Support
```kotlin
@Test
fun testMultiRegionSupport() {
    val regions = listOf("singapore")  // Expand as needed

    regions.forEach { region ->
        val actor = Actor.createWithExternalTiles(region)
        // Test route in this region
        actor.close()
    }
}
```

#### Scenario 3: Error Handling
```kotlin
@Test
fun testErrorHandling() {
    val actor = Actor.createWithExternalTiles("singapore")

    // Invalid location
    assertThrows<Exception> {
        val request = RouteRequest(
            locations = listOf(
                RouteRequest.Location(999.0, 999.0),
                RouteRequest.Location(1.352083, 103.819836)
            ),
            costing = "auto"
        )
        actor.route(request)
    }

    actor.close()
}
```

### Running Integration Tests

```bash
# All integration tests
./gradlew test --tests '*IntegrationTest'

# Specific test
./gradlew test --tests '*IntegrationTest.testEndToEndRoutingWorkflow'

# With logging
./gradlew test --tests '*IntegrationTest' --info
```

---

## 📊 Monitoring Setup

### Architecture

```
┌─────────────────┐
│  Valhalla JNI   │
│  Application    │
└────────┬────────┘
         │ Metrics
         ↓
┌─────────────────┐
│   Prometheus    │  ← Scrapes metrics every 10s
│   (Time-series  │
│   Database)     │
└────────┬────────┘
         │ Query
         ↓
┌─────────────────┐
│    Grafana      │  ← Visualization
│   (Dashboards)  │
└─────────────────┘

┌─────────────────┐
│  Alertmanager   │  ← Sends alerts
│  (Alerting)     │
└─────────────────┘
```

### Prometheus Configuration

**File**: `monitoring/prometheus.yml` (already created in docker/)

**Scrape Config**:
```yaml
scrape_configs:
  - job_name: 'valhalla-jni'
    metrics_path: '/metrics'
    scrape_interval: 10s
    static_configs:
      - targets: ['valhalla-jni:8080']
```

**Start Prometheus**:
```bash
# Docker
cd docker
docker-compose up -d prometheus

# Or standalone
prometheus --config.file=monitoring/prometheus.yml
```

### Grafana Dashboard

**File**: `monitoring/grafana-dashboard-valhalla.json`

**Import Dashboard**:
1. Open Grafana (http://localhost:3000)
2. Login (admin/admin)
3. Go to Dashboards → Import
4. Upload `monitoring/grafana-dashboard-valhalla.json`

**Dashboard Panels**:
1. **Request Rate** - Routes per second
2. **Success Rate** - Percentage of successful routes
3. **Latency** - p50, p95, p99 latencies
4. **Error Rate** - Percentage of failed routes
5. **Active Actors** - Number of active instances
6. **Requests by Region** - Regional distribution
7. **Requests by Costing** - Costing type distribution
8. **JVM Memory** - Heap usage

---

## 📈 Metrics Collection

### Metrics Exported

#### Request Metrics
- `valhalla_route_requests_total` - Total route requests (counter)
- `valhalla_route_requests_success` - Successful routes (counter)
- `valhalla_route_requests_failed` - Failed routes (counter)

#### Latency Metrics
- `valhalla_route_latency_ms{quantile="0.5"}` - p50 latency
- `valhalla_route_latency_ms{quantile="0.95"}` - p95 latency
- `valhalla_route_latency_ms{quantile="0.99"}` - p99 latency

#### System Metrics
- `valhalla_active_actors` - Number of active Actor instances (gauge)
- `valhalla_error_rate_percent` - Error rate percentage (gauge)
- `valhalla_request_rate_per_second` - Request rate (gauge)

#### Regional Metrics
- `valhalla_requests_by_region{region="singapore"}` - Requests per region (counter)
- `valhalla_requests_by_costing{costing="auto"}` - Requests per costing (counter)

### Accessing Metrics

#### Programmatic Access
```kotlin
import global.tada.valhalla.metrics.ValhallaMetrics

// Get snapshot
val snapshot = ValhallaMetrics.getSnapshot()

println("Total requests: ${snapshot.totalRequests}")
println("Average latency: ${snapshot.averageLatencyMs}ms")
println("Error rate: ${snapshot.errorRate}%")
```

#### Prometheus Format
```kotlin
val prometheusMetrics = ValhallaMetrics.exportPrometheusMetrics()
println(prometheusMetrics)
```

#### HTTP Endpoint (if implemented)
```bash
curl http://localhost:8080/metrics
```

### Metrics in Code

```kotlin
import global.tada.valhalla.metrics.ValhallaMetrics

// Record successful route
val startTime = System.currentTimeMillis()
val response = actor.route(request)
val latency = System.currentTimeMillis() - startTime

ValhallaMetrics.recordRouteSuccess(
    region = "singapore",
    costing = "auto",
    latencyMs = latency
)

// Record failure
try {
    actor.route(invalidRequest)
} catch (e: Exception) {
    ValhallaMetrics.recordRouteFailure(
        region = "singapore",
        costing = "auto",
        error = e.message ?: "Unknown error"
    )
}
```

---

## 🚨 Alerting

### Alert Rules

**File**: `monitoring/prometheus-alerts.yml`

**Critical Alerts**:
1. **High Error Rate** (> 5% for 5 min)
2. **Very High Error Rate** (> 20% for 1 min)
3. **High Latency** (p95 > 100ms for 5 min)
4. **Very High Latency** (p95 > 500ms for 2 min)
5. **Critical Memory Usage** (> 95% for 2 min)

**Warning Alerts**:
1. **No Requests** (0 req/s for 5 min)
2. **Low Request Rate** (< 1 req/s for 10 min)
3. **Too Many Active Actors** (> 100 for 5 min)
4. **Success Rate Drop** (< 95% for 5 min)

### Configuring Alerts

**Load alert rules**:
```bash
# Prometheus configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - 'monitoring/prometheus-alerts.yml'
```

**Restart Prometheus**:
```bash
docker-compose restart prometheus
```

### Alert Destinations

**Alertmanager Config** (`alertmanager.yml`):
```yaml
route:
  receiver: 'team-notifications'

receivers:
  - name: 'team-notifications'
    email_configs:
      - to: 'team@example.com'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK_URL'
        channel: '#valhalla-alerts'
```

---

## 🔧 Troubleshooting

### High Latency

**Symptoms**:
- p95 latency > 100ms
- Slow route calculations

**Diagnosis**:
```bash
# Check metrics
curl http://localhost:9090/api/v1/query?query=valhalla_route_latency_ms

# Run benchmarks
./scripts/run-benchmarks.sh all

# Check system resources
top
htop
```

**Solutions**:
1. **Increase JVM heap**: Edit `gradle.properties` or Docker memory limits
2. **Check tile cache**: Ensure tiles are loaded and accessible
3. **Reduce concurrency**: Limit concurrent requests
4. **Profile code**: Use JMH benchmarks to identify bottlenecks

### High Error Rate

**Symptoms**:
- Error rate > 5%
- Many failed requests

**Diagnosis**:
```bash
# Check logs
./gradlew test --tests '*LoadTest.testErrorHandlingUnderStress' --info

# Check error types
grep "ERROR" build/reports/load-tests/*.log
```

**Solutions**:
1. **Validate configuration**: Run `RegionConfigValidator.validate()`
2. **Check tile availability**: Ensure tile directories exist
3. **Verify request format**: Check request JSON structure
4. **Review error logs**: Identify common error patterns

### Memory Leaks

**Symptoms**:
- Memory usage grows continuously
- OutOfMemoryError after extended use

**Diagnosis**:
```bash
# Run memory stability test
./scripts/load-test.sh memory

# Heap dump
jmap -dump:live,format=b,file=heap.hprof <pid>

# Analyze with VisualVM or MAT
visualvm heap.hprof
```

**Solutions**:
1. **Check Actor cleanup**: Ensure `actor.close()` is called
2. **Review JNI code**: Check for local ref leaks (Phase 1 fixes should prevent this)
3. **Increase heap**: `-Xmx8g` in production
4. **Enable GC logging**: `-Xlog:gc*:file=gc.log`

### Low Throughput

**Symptoms**:
- Request rate < 40 routes/sec
- Slow performance

**Diagnosis**:
```bash
# Run benchmarks
./scripts/run-benchmarks.sh concurrent

# Check CPU usage
top -H
```

**Solutions**:
1. **Increase parallelism**: More concurrent workers
2. **Optimize tile access**: Use SSD for tile storage
3. **Tune JVM**: G1GC with appropriate heap size
4. **Profile CPU**: Use JFR (Java Flight Recorder)

---

## 📋 Testing Checklist

### Before Deployment

- [ ] All unit tests pass (`./gradlew test`)
- [ ] Integration tests pass (`./gradlew test --tests '*IntegrationTest'`)
- [ ] Load tests pass (`./scripts/load-test.sh all`)
- [ ] Benchmarks meet targets (`./scripts/run-benchmarks.sh all`)
- [ ] Configuration validated (`RegionConfigValidator.validate()`)
- [ ] Metrics exported correctly
- [ ] Grafana dashboard configured
- [ ] Alert rules loaded
- [ ] Documentation reviewed

### In Production

- [ ] Monitoring dashboards accessible
- [ ] Alerts configured and tested
- [ ] Metrics being scraped by Prometheus
- [ ] Baseline performance established
- [ ] Error rate < 1%
- [ ] p95 latency < 50ms
- [ ] Success rate > 99%
- [ ] No memory leaks detected

---

## 📚 Additional Resources

- **JMH Tutorial**: https://openjdk.org/projects/code-tools/jmh/
- **Prometheus Docs**: https://prometheus.io/docs/
- **Grafana Docs**: https://grafana.com/docs/
- **Load Testing Best Practices**: https://k6.io/docs/
- **JVM Performance Tuning**: https://docs.oracle.com/en/java/javase/17/gctuning/

---

**Questions?** Check the troubleshooting section or consult PHASE5_IMPLEMENTATION.md for detailed metrics and testing information.
