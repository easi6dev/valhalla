# Valhalla JNI Bindings - Production Deployment Guide

Complete guide for deploying Valhalla JNI bindings in production environments with Docker, Kubernetes, monitoring, and scaling strategies.

**Date**: February 23, 2026
**Branch**: `master`
**Target Audience**: DevOps Engineers, SREs, Platform Engineers

---

## 📋 Table of Contents

1. [Production Architecture](#production-architecture)
2. [Docker Deployment](#docker-deployment)
3. [Kubernetes Deployment](#kubernetes-deployment)
4. [Configuration Management](#configuration-management)
5. [Monitoring & Observability](#monitoring--observability)
6. [Scaling Strategies](#scaling-strategies)
7. [Security Hardening](#security-hardening)
8. [Disaster Recovery](#disaster-recovery)
9. [Performance Tuning](#performance-tuning)
10. [Troubleshooting](#troubleshooting)

---

## 🏗️ Production Architecture

### Overview

```
┌─────────────────────────────────────────────────────────────┐
│                        Load Balancer                         │
│                    (Nginx / AWS ALB)                        │
└────────────────────┬────────────────────────────────────────┘
                     │
          ┌──────────┴──────────┐
          │                     │
┌─────────▼────────┐  ┌────────▼─────────┐
│  Routing Service │  │  Routing Service  │  (Auto-scaled)
│   (Container)    │  │   (Container)     │
│                  │  │                   │
│ • JVM (Java 17)  │  │ • JVM (Java 17)   │
│ • Valhalla JNI   │  │ • Valhalla JNI    │
│ • Tiles cached   │  │ • Tiles cached    │
└─────────┬────────┘  └────────┬──────────┘
          │                    │
          └──────────┬─────────┘
                     │
         ┌───────────▼───────────┐
         │   Shared Tile Storage │
         │   (NFS / EBS / S3)    │
         └───────────────────────┘

         ┌───────────────────────┐
         │   Monitoring Stack    │
         │ • Prometheus          │
         │ • Grafana             │
         │ • Alertmanager        │
         └───────────────────────┘
```

### System Requirements (Per Instance)

| Component | Minimum | Recommended | Notes |
|-----------|---------|-------------|-------|
| **CPU** | 2 cores | 4 cores | For Singapore tiles |
| **RAM** | 4GB | 8GB | Depends on region size |
| **Disk** | 10GB | 20GB | For logs + cache |
| **Network** | 1Gbps | 10Gbps | For high throughput |
| **Tile Storage** | 2GB | Varies | Per region |

### Capacity Planning

**Singapore Region**:
- Tile size: ~2GB
- Memory footprint: ~150MB (tiles loaded)
- Route calculation: ~15ms average
- Throughput: ~500-1000 routes/sec per instance

**Thailand Region**:
- Tile size: ~5GB
- Memory footprint: ~400MB (tiles loaded)
- Route calculation: ~25ms average
- Throughput: ~300-500 routes/sec per instance

**Scaling Formula**:
```
Required Instances = (Peak RPS × Average Response Time) / Target CPU %
                   = (1000 RPS × 0.015s) / 0.70
                   = ~21 instances (for 1000 RPS @ 70% CPU)
```

---

## 🐳 Docker Deployment

### Production Dockerfile

**File**: `docker/Dockerfile.prod`

```dockerfile
# ============================================
# Stage 1: Build Valhalla + JNI Bindings
# ============================================
FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    cmake g++ make ninja-build git \
    libboost-all-dev libcurl4-openssl-dev \
    libprotobuf-dev protobuf-compiler \
    libsqlite3-dev libspatialite-dev \
    liblz4-dev libgeos-dev liblua5.3-dev \
    openjdk-17-jdk gradle \
    && rm -rf /var/lib/apt/lists/*

# Copy source
WORKDIR /build
COPY . .

# Build Valhalla + JNI bindings
RUN cd src/bindings/java && \
    ./build-jni-bindings.sh && \
    ./bundle-production-jar.sh

# ============================================
# Stage 2: Runtime Image (Minimal)
# ============================================
FROM ubuntu:22.04

# Install runtime dependencies only (system libraries)
RUN apt-get update && apt-get install -y \
    openjdk-17-jre-headless \
    libcurl4 libprotobuf23 \
    libsqlite3-0 libspatialite7 \
    liblz4-1 libgeos-c1v5 \
    liblua5.3-0 \
    && rm -rf /var/lib/apt/lists/*

# Create app user (non-root)
RUN useradd -m -u 1000 -s /bin/bash valhalla && \
    mkdir -p /var/valhalla/tiles /var/log/valhalla && \
    chown -R valhalla:valhalla /var/valhalla /var/log/valhalla

# Copy binaries and libraries from builder
COPY --from=builder /build/build/src/bindings/java/libvalhalla_jni.so /usr/local/lib/
COPY --from=builder /build/src/bindings/java/build/libs/valhalla-jni.jar /app/
COPY --from=builder /build/config /app/config

# Copy your application JAR (if separate)
# COPY --from=builder /build/your-app.jar /app/

# Set library path
ENV LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
ENV VALHALLA_TILE_DIR=/var/valhalla/tiles

# Switch to non-root user
USER valhalla
WORKDIR /app

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD java -cp /app/valhalla-jni.jar global.tada.valhalla.HealthCheck || exit 1

# Expose port (if running HTTP service)
EXPOSE 8080

# Start application
CMD ["java", \
     "-Xmx4g", \
     "-Xms2g", \
     "-XX:+UseG1GC", \
     "-XX:MaxGCPauseMillis=200", \
     "-XX:+HeapDumpOnOutOfMemoryError", \
     "-XX:HeapDumpPath=/var/log/valhalla/heap-dump.hprof", \
     "-Djava.library.path=/usr/local/lib", \
     "-Dvalhalla.env=prod", \
     "-jar", "/app/your-app.jar"]
```

### Build and Run

```bash
# Build production image
docker build -f docker/Dockerfile.prod -t valhalla-jni:latest .

# Run container
docker run -d \
    --name valhalla-jni \
    -p 8080:8080 \
    -v /mnt/tiles:/var/valhalla/tiles:ro \
    -v /var/log/valhalla:/var/log/valhalla \
    -e VALHALLA_TILE_DIR=/var/valhalla/tiles \
    --memory=8g \
    --cpus=4 \
    --restart=unless-stopped \
    valhalla-jni:latest

# Check logs
docker logs -f valhalla-jni

# Health check
curl http://localhost:8080/health
```

### Docker Compose

**File**: `docker/docker-compose.yml`

```yaml
version: '3.8'

services:
  valhalla-jni:
    build:
      context: ..
      dockerfile: docker/Dockerfile.prod
    image: valhalla-jni:latest
    container_name: valhalla-jni
    ports:
      - "8080:8080"
    volumes:
      # Tile data (read-only)
      - /mnt/tiles:/var/valhalla/tiles:ro
      # Logs (persistent)
      - valhalla-logs:/var/log/valhalla
      # Config (read-only)
      - ../config:/app/config:ro
    environment:
      - VALHALLA_TILE_DIR=/var/valhalla/tiles
      - JAVA_OPTS=-Xmx4g -Xms2g -XX:+UseG1GC
    deploy:
      resources:
        limits:
          cpus: '4'
          memory: 8G
        reservations:
          cpus: '2'
          memory: 4G
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped
    networks:
      - valhalla-net

  # Prometheus monitoring
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
    networks:
      - valhalla-net

  # Grafana dashboards
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana-dashboards:/etc/grafana/provisioning/dashboards:ro
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    networks:
      - valhalla-net

volumes:
  valhalla-logs:
  prometheus-data:
  grafana-data:

networks:
  valhalla-net:
    driver: bridge
```

**Start Stack**:
```bash
cd docker
docker-compose up -d

# Check services
docker-compose ps

# View logs
docker-compose logs -f valhalla-jni
```

---

## ☸️ Kubernetes Deployment

### Namespace

**File**: `k8s/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: valhalla
  labels:
    name: valhalla
    environment: production
```

### ConfigMap

**File**: `k8s/configmap.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: valhalla-config
  namespace: valhalla
data:
  VALHALLA_TILE_DIR: "/var/valhalla/tiles"
  JAVA_OPTS: "-Xmx4g -Xms2g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
  LOG_LEVEL: "INFO"

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: valhalla-regions-config
  namespace: valhalla
data:
  regions.json: |
    {
      "regions": {
        "singapore": {
          "name": "Singapore",
          "enabled": true,
          "tile_dir": "/var/valhalla/tiles/singapore",
          "bounds": {
            "min_lat": 1.15,
            "max_lat": 1.48,
            "min_lon": 103.6,
            "max_lon": 104.0
          },
          "default_costing": "auto",
          "supported_costings": ["auto", "taxi", "motorcycle"]
        }
      }
    }
```

### Persistent Volume

**File**: `k8s/pv-tiles.yaml`

```yaml
# For NFS-based tile storage
apiVersion: v1
kind: PersistentVolume
metadata:
  name: valhalla-tiles-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadOnlyMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs
  nfs:
    server: nfs-server.example.com
    path: /mnt/valhalla/tiles
    readOnly: true

---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: valhalla-tiles-pvc
  namespace: valhalla
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: nfs
  resources:
    requests:
      storage: 100Gi
```

### Deployment

**File**: `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-jni
  namespace: valhalla
  labels:
    app: valhalla-jni
    version: v1
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  selector:
    matchLabels:
      app: valhalla-jni
  template:
    metadata:
      labels:
        app: valhalla-jni
        version: v1
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8080"
        prometheus.io/path: "/metrics"
    spec:
      # Security context
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000

      # Node affinity (prefer nodes with SSD)
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: disk-type
                    operator: In
                    values:
                      - ssd

        # Pod anti-affinity (spread across nodes)
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - valhalla-jni
                topologyKey: kubernetes.io/hostname

      containers:
        - name: valhalla-jni
          image: your-registry/valhalla-jni:latest
          imagePullPolicy: Always

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

          env:
            - name: VALHALLA_TILE_DIR
              valueFrom:
                configMapKeyRef:
                  name: valhalla-config
                  key: VALHALLA_TILE_DIR
            - name: JAVA_OPTS
              valueFrom:
                configMapKeyRef:
                  name: valhalla-config
                  key: JAVA_OPTS
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace

          resources:
            requests:
              memory: "4Gi"
              cpu: "2000m"
            limits:
              memory: "8Gi"
              cpu: "4000m"

          volumeMounts:
            # Tile data (read-only)
            - name: tiles
              mountPath: /var/valhalla/tiles
              readOnly: true
            # Config files
            - name: config
              mountPath: /app/config
              readOnly: true
            # Logs (ephemeral)
            - name: logs
              mountPath: /var/log/valhalla

          # Liveness probe
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 60
            periodSeconds: 30
            timeoutSeconds: 10
            failureThreshold: 3

          # Readiness probe
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

          # Startup probe (for slow starts)
          startupProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12  # 2 minutes max

      volumes:
        - name: tiles
          persistentVolumeClaim:
            claimName: valhalla-tiles-pvc
        - name: config
          configMap:
            name: valhalla-regions-config
        - name: logs
          emptyDir: {}

      # Graceful shutdown
      terminationGracePeriodSeconds: 30
```

### Service

**File**: `k8s/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: valhalla-jni
  namespace: valhalla
  labels:
    app: valhalla-jni
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
      name: http
  selector:
    app: valhalla-jni
```

### Horizontal Pod Autoscaler

**File**: `k8s/hpa.yaml`

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: valhalla-jni-hpa
  namespace: valhalla
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: valhalla-jni
  minReplicas: 3
  maxReplicas: 20
  metrics:
    # CPU-based scaling
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70

    # Memory-based scaling
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80

    # Custom metric: requests per second
    - type: Pods
      pods:
        metric:
          name: http_requests_per_second
        target:
          type: AverageValue
          averageValue: "500"

  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
        - type: Pods
          value: 2
          periodSeconds: 60
      selectPolicy: Max

    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Percent
          value: 25
          periodSeconds: 60
        - type: Pods
          value: 1
          periodSeconds: 60
      selectPolicy: Min
```

### Ingress

**File**: `k8s/ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: valhalla-jni-ingress
  namespace: valhalla
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/rate-limit: "1000"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - routing.example.com
      secretName: valhalla-tls
  rules:
    - host: routing.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: valhalla-jni
                port:
                  number: 80
```

### Deploy to Kubernetes

```bash
# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create ConfigMaps
kubectl apply -f k8s/configmap.yaml

# Create PV/PVC
kubectl apply -f k8s/pv-tiles.yaml

# Deploy application
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/ingress.yaml

# Check deployment
kubectl get pods -n valhalla
kubectl get svc -n valhalla
kubectl get hpa -n valhalla

# Check logs
kubectl logs -f deployment/valhalla-jni -n valhalla

# Exec into pod
kubectl exec -it -n valhalla deployment/valhalla-jni -- bash
```

---

## ⚙️ Configuration Management

### Environment Configuration

Production uses `config/regions/regions.json` with environment-specific tile directory:

**Environment Variable**: `VALHALLA_TILE_DIR=/var/valhalla/tiles`

```json
{
  "regions": {
    "singapore": {
      "name": "Singapore",
      "enabled": true,
      "tile_dir": "singapore",
      "default_costing": "auto",
      "supported_costings": ["auto", "taxi", "motorcycle", "bicycle", "pedestrian", "bus", "truck"],
      "timezone": "Asia/Singapore",
      "locale": "en-SG",
      "currency": "SGD"
    }
  },
  "metadata": {
    "version": "1.0.0",
    "last_updated": "2026-02-24",
    "tile_dir_config": {
      "description": "Configure tile directory root via VALHALLA_TILE_DIR environment variable",
      "default": "data/valhalla_tiles",
      "examples": {
        "development": "data/valhalla_tiles",
        "production": "/var/valhalla/tiles"
      }
    }
  }
}
```

### Secrets Management

**With Kubernetes Secrets**:

```bash
# Create secret
kubectl create secret generic valhalla-secrets \
    --from-literal=api-key=YOUR_API_KEY \
    --namespace=valhalla

# Use in deployment
env:
  - name: API_KEY
    valueFrom:
      secretKeyRef:
        name: valhalla-secrets
        key: api-key
```

**With HashiCorp Vault**:

```bash
# Store secret
vault kv put secret/valhalla/prod api_key=YOUR_API_KEY

# Inject via sidecar or init container
```

---

## 📊 Monitoring & Observability

### Prometheus Metrics

**Expose metrics** in your application:

```kotlin
import io.prometheus.client.Counter
import io.prometheus.client.Histogram

object ValhallaMetrics {
    val routeRequests = Counter.build()
        .name("valhalla_route_requests_total")
        .help("Total route requests")
        .labelNames("region", "costing", "status")
        .register()

    val routeLatency = Histogram.build()
        .name("valhalla_route_latency_seconds")
        .help("Route calculation latency")
        .labelNames("region", "costing")
        .buckets(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
        .register()

    val activeActors = Gauge.build()
        .name("valhalla_active_actors")
        .help("Number of active Actor instances")
        .register()
}

// Usage
fun route(request: RouteRequest): RouteResponse {
    val timer = ValhallaMetrics.routeLatency
        .labels(request.region, request.costing)
        .startTimer()

    try {
        val response = actor.route(request)
        ValhallaMetrics.routeRequests
            .labels(request.region, request.costing, "success")
            .inc()
        return response
    } catch (e: Exception) {
        ValhallaMetrics.routeRequests
            .labels(request.region, request.costing, "error")
            .inc()
        throw e
    } finally {
        timer.observeDuration()
    }
}
```

### Grafana Dashboards

**Key Metrics**:
- Request rate (RPS)
- Latency (p50, p95, p99)
- Error rate
- CPU/Memory usage
- JVM heap usage
- GC pause time

**Sample Dashboard JSON**: See `k8s/grafana-dashboards/valhalla-dashboard.json`

### Alerting Rules

**File**: `k8s/prometheus-rules.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: valhalla-alerts
  namespace: valhalla
spec:
  groups:
    - name: valhalla
      interval: 30s
      rules:
        # High error rate
        - alert: HighErrorRate
          expr: |
            rate(valhalla_route_requests_total{status="error"}[5m])
            / rate(valhalla_route_requests_total[5m]) > 0.05
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "High error rate ({{ $value | humanizePercentage }})"
            description: "Error rate is above 5% for 5 minutes"

        # High latency
        - alert: HighLatency
          expr: |
            histogram_quantile(0.95,
              rate(valhalla_route_latency_seconds_bucket[5m])
            ) > 1.0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High latency (p95 = {{ $value }}s)"
            description: "95th percentile latency is above 1 second"

        # Pod down
        - alert: PodDown
          expr: |
            up{job="valhalla-jni"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Valhalla pod is down"
            description: "Pod {{ $labels.pod }} is unreachable"
```

---

## 🚀 Scaling Strategies

### Vertical Scaling

Increase resources per pod:

```yaml
resources:
  requests:
    memory: "8Gi"   # Increased from 4Gi
    cpu: "4000m"    # Increased from 2000m
  limits:
    memory: "16Gi"  # Increased from 8Gi
    cpu: "8000m"    # Increased from 4000m
```

### Horizontal Scaling

Increase number of pods (via HPA):

```bash
# Manual scaling
kubectl scale deployment valhalla-jni --replicas=10 -n valhalla

# Auto-scaling (HPA configured above)
# Scales between 3-20 pods based on CPU/memory/custom metrics
```

### Regional Scaling

Deploy separate instances per region:

```yaml
# Singapore deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-jni-singapore
spec:
  template:
    spec:
      containers:
        - name: valhalla-jni
          env:
            - name: VALHALLA_REGION
              value: "singapore"
          volumeMounts:
            - name: tiles
              mountPath: /var/valhalla/tiles/singapore

---
# Thailand deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-jni-thailand
spec:
  template:
    spec:
      containers:
        - name: valhalla-jni
          env:
            - name: VALHALLA_REGION
              value: "thailand"
          volumeMounts:
            - name: tiles
              mountPath: /var/valhalla/tiles/thailand
```

---

## 🔒 Security Hardening

### Container Security

```dockerfile
# Run as non-root
USER 1000:1000

# Read-only root filesystem
docker run --read-only --tmpfs /tmp valhalla-jni:latest

# Drop capabilities
docker run --cap-drop=ALL valhalla-jni:latest
```

### Network Policies

**File**: `k8s/network-policy.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: valhalla-jni-netpol
  namespace: valhalla
spec:
  podSelector:
    matchLabels:
      app: valhalla-jni
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from ingress controller
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
  egress:
    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

### Pod Security Policy

```yaml
apiVersion: policy/v1beta1
kind: PodSecurityPolicy
metadata:
  name: valhalla-psp
spec:
  privileged: false
  allowPrivilegeEscalation: false
  requiredDropCapabilities:
    - ALL
  runAsUser:
    rule: MustRunAsNonRoot
  fsGroup:
    rule: RunAsAny
  readOnlyRootFilesystem: true
```

---

## 🔄 Disaster Recovery

### Backup Strategy

**Tile Data**:
```bash
# Backup tiles (daily)
rsync -avz --progress \
    /mnt/valhalla/tiles/ \
    backup-server:/backups/valhalla/tiles-$(date +%Y%m%d)/

# Or use cloud storage
aws s3 sync /mnt/valhalla/tiles/ s3://backups/valhalla/tiles/
```

**Configuration**:
```bash
# Version control configs
git add config/regions/
git commit -m "Update production config"
git push
```

### Disaster Recovery Plan

1. **RPO** (Recovery Point Objective): 24 hours (daily tile backups)
2. **RTO** (Recovery Time Objective): 30 minutes (restore from backup)

**Recovery Steps**:
```bash
# 1. Restore tiles from backup
aws s3 sync s3://backups/valhalla/tiles/ /mnt/valhalla/tiles/

# 2. Redeploy from Git
git checkout master
kubectl apply -f k8s/

# 3. Verify health
kubectl get pods -n valhalla
curl https://routing.example.com/health
```

---

## 🎯 Performance Tuning

### JVM Tuning

```bash
# Use G1GC for low-latency
JAVA_OPTS="-XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# Tune heap size
JAVA_OPTS="-Xmx8g -Xms4g"

# Enable GC logging
JAVA_OPTS="-Xlog:gc*:file=/var/log/valhalla/gc.log:time,uptime,level,tags"
```

### System Tuning

```bash
# Increase file descriptors
ulimit -n 65536

# TCP tuning
sysctl -w net.core.somaxconn=8192
sysctl -w net.ipv4.tcp_max_syn_backlog=8192
```

---

## 🐛 Troubleshooting

### High Memory Usage

```bash
# Check memory
kubectl top pods -n valhalla

# Heap dump
kubectl exec -it -n valhalla deployment/valhalla-jni -- \
    jmap -dump:live,format=b,file=/tmp/heap.hprof $(pgrep java)

# Analyze with MAT or VisualVM
```

### High CPU Usage

```bash
# Profile CPU
kubectl exec -it -n valhalla deployment/valhalla-jni -- \
    jcmd $(pgrep java) JFR.start duration=60s filename=/tmp/profile.jfr

# Analyze with JMC
```

### Slow Routes

```bash
# Check tile cache
# Enable debug logging
kubectl set env deployment/valhalla-jni LOG_LEVEL=DEBUG -n valhalla

# Check logs
kubectl logs -f deployment/valhalla-jni -n valhalla | grep "route calculation"
```

---

## ✅ Production Checklist

Before going live:

- [ ] Docker image built and tested
- [ ] Kubernetes manifests validated
- [ ] Tile data uploaded and verified
- [ ] Configuration validated (no errors)
- [ ] Health checks passing
- [ ] Monitoring dashboards created
- [ ] Alerting rules configured
- [ ] Auto-scaling tested
- [ ] Disaster recovery plan documented
- [ ] Load testing completed
- [ ] Security hardening applied
- [ ] Documentation reviewed

**Ready for production! 🚀**

---

## 📚 Additional Resources

- **Quick Start**: See [QUICKSTART.md](QUICKSTART.md)
- **Development**: See [DEVELOPMENT.md](DEVELOPMENT.md)
- **Kubernetes Best Practices**: https://kubernetes.io/docs/concepts/configuration/overview/
- **Docker Best Practices**: https://docs.docker.com/develop/dev-best-practices/

---

**Questions?** Reach out to the DevOps team or check the troubleshooting section above.
