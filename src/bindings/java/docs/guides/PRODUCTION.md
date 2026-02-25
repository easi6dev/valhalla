# Valhalla JNI Bindings - Production Deployment Guide

Complete guide for deploying Valhalla JNI bindings in production environments with Docker, AWS ECS, monitoring, and scaling strategies.

**Date**: February 25, 2026
**Branch**: `master`
**Target Audience**: DevOps Engineers, SREs, Platform Engineers

---

## 📋 Table of Contents

1. [Production Architecture](#production-architecture)
2. [Docker Deployment](#docker-deployment)
3. [AWS ECS Deployment](#aws-ecs-deployment)
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
      # Note: Grafana monitoring removed, to be replaced with Datadog in Phase 6
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

## ☁️ AWS ECS Deployment

### Prerequisites

1. **AWS Account** with ECS permissions
2. **ECR Repository** for Docker images
3. **EFS Filesystem** for shared tile storage (optional, can use EBS)
4. **VPC** with public/private subnets
5. **Application Load Balancer** (ALB)

### Push Image to ECR

```bash
# Authenticate to ECR
aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com

# Build and tag image
docker build -f docker/Dockerfile.prod -t valhalla-jni:latest .
docker tag valhalla-jni:latest YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/valhalla-jni:latest

# Push to ECR
docker push YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/valhalla-jni:latest
```

### ECS Task Definition

**File**: `ecs-task-definition.json`

```json
{
  "family": "valhalla-jni",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "2048",
  "memory": "8192",
  "executionRoleArn": "arn:aws:iam::YOUR_ACCOUNT:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::YOUR_ACCOUNT:role/valhalla-jni-task-role",
  "containerDefinitions": [
    {
      "name": "valhalla-jni",
      "image": "YOUR_ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/valhalla-jni:latest",
      "cpu": 2048,
      "memory": 8192,
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8080,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "VALHALLA_TILE_DIR",
          "value": "/var/valhalla/tiles"
        },
        {
          "name": "JAVA_OPTS",
          "value": "-Xmx6g -Xms4g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"
        },
        {
          "name": "LOG_LEVEL",
          "value": "INFO"
        }
      ],
      "mountPoints": [
        {
          "sourceVolume": "tiles",
          "containerPath": "/var/valhalla/tiles",
          "readOnly": true
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/valhalla-jni",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
        "interval": 30,
        "timeout": 10,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ],
  "volumes": [
    {
      "name": "tiles",
      "efsVolumeConfiguration": {
        "fileSystemId": "fs-XXXXXXXX",
        "transitEncryption": "ENABLED",
        "authorizationConfig": {
          "iam": "ENABLED"
        }
      }
    }
  ]
}
```

### Create ECS Cluster

```bash
# Create cluster
aws ecs create-cluster \
    --cluster-name valhalla-production \
    --region us-east-1

# Register task definition
aws ecs register-task-definition \
    --cli-input-json file://ecs-task-definition.json

# Create CloudWatch log group
aws logs create-log-group \
    --log-group-name /ecs/valhalla-jni \
    --region us-east-1
```

### Create ECS Service with ALB

```bash
# Create service
aws ecs create-service \
    --cluster valhalla-production \
    --service-name valhalla-jni-service \
    --task-definition valhalla-jni:1 \
    --desired-count 3 \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={
        subnets=[subnet-xxx,subnet-yyy],
        securityGroups=[sg-xxx],
        assignPublicIp=DISABLED
    }" \
    --load-balancers "targetGroupArn=arn:aws:elasticloadbalancing:us-east-1:YOUR_ACCOUNT:targetgroup/valhalla-tg/xxx,
        containerName=valhalla-jni,
        containerPort=8080" \
    --health-check-grace-period-seconds 120 \
    --deployment-configuration "maximumPercent=200,minimumHealthyPercent=100,
        deploymentCircuitBreaker={enable=true,rollback=true}"
```

### Auto Scaling Configuration

```bash
# Register scalable target
aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id service/valhalla-production/valhalla-jni-service \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 3 \
    --max-capacity 20

# Create scaling policy (CPU-based)
aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/valhalla-production/valhalla-jni-service \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name valhalla-cpu-scaling \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration '{
        "TargetValue": 70.0,
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
        },
        "ScaleInCooldown": 300,
        "ScaleOutCooldown": 60
    }'

# Create scaling policy (Memory-based)
aws application-autoscaling put-scaling-policy \
    --service-namespace ecs \
    --resource-id service/valhalla-production/valhalla-jni-service \
    --scalable-dimension ecs:service:DesiredCount \
    --policy-name valhalla-memory-scaling \
    --policy-type TargetTrackingScaling \
    --target-tracking-scaling-policy-configuration '{
        "TargetValue": 80.0,
        "PredefinedMetricSpecification": {
            "PredefinedMetricType": "ECSServiceAverageMemoryUtilization"
        },
        "ScaleInCooldown": 300,
        "ScaleOutCooldown": 60
    }'
```

### EFS Setup for Tile Storage

```bash
# Create EFS filesystem
aws efs create-file-system \
    --performance-mode generalPurpose \
    --throughput-mode bursting \
    --encrypted \
    --tags Key=Name,Value=valhalla-tiles \
    --region us-east-1

# Create mount targets in each subnet
aws efs create-mount-target \
    --file-system-id fs-XXXXXXXX \
    --subnet-id subnet-xxx \
    --security-groups sg-efs \
    --region us-east-1

# Mount EFS and upload tiles (from EC2 instance)
sudo mkdir -p /mnt/efs
sudo mount -t efs -o tls fs-XXXXXXXX:/ /mnt/efs
sudo aws s3 sync s3://your-tiles-bucket/ /mnt/efs/tiles/
```

### Monitoring with CloudWatch

```bash
# Create CloudWatch dashboard
aws cloudwatch put-dashboard \
    --dashboard-name valhalla-jni-production \
    --dashboard-body file://cloudwatch-dashboard.json

# Create alarms
aws cloudwatch put-metric-alarm \
    --alarm-name valhalla-high-cpu \
    --alarm-description "Valhalla ECS service high CPU" \
    --metric-name CPUUtilization \
    --namespace AWS/ECS \
    --statistic Average \
    --period 300 \
    --threshold 80 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --dimensions Name=ServiceName,Value=valhalla-jni-service \
                 Name=ClusterName,Value=valhalla-production

aws cloudwatch put-metric-alarm \
    --alarm-name valhalla-high-memory \
    --alarm-description "Valhalla ECS service high memory" \
    --metric-name MemoryUtilization \
    --namespace AWS/ECS \
    --statistic Average \
    --period 300 \
    --threshold 85 \
    --comparison-operator GreaterThanThreshold \
    --evaluation-periods 2 \
    --dimensions Name=ServiceName,Value=valhalla-jni-service \
                 Name=ClusterName,Value=valhalla-production
```

### Deployment Updates

```bash
# Update task definition with new image
aws ecs register-task-definition \
    --cli-input-json file://ecs-task-definition.json

# Update service to use new task definition
aws ecs update-service \
    --cluster valhalla-production \
    --service valhalla-jni-service \
    --task-definition valhalla-jni:2 \
    --force-new-deployment

# Monitor deployment
aws ecs describe-services \
    --cluster valhalla-production \
    --services valhalla-jni-service \
    --query 'services[0].deployments'
```

### Verify Deployment

```bash
# Check service status
aws ecs describe-services \
    --cluster valhalla-production \
    --services valhalla-jni-service

# Check running tasks
aws ecs list-tasks \
    --cluster valhalla-production \
    --service-name valhalla-jni-service

# View logs
aws logs tail /ecs/valhalla-jni --follow

# Test via ALB
curl https://routing.example.com/health
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

**Note**: Grafana monitoring is being replaced with Datadog in Phase 6. Sample dashboards will be provided in the Datadog integration.

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

### Vertical Scaling (Docker Compose)

Increase resources per container:

```yaml
# docker-compose.yml
services:
  valhalla-jni:
    deploy:
      resources:
        limits:
          cpus: '8'      # Increased from 4
          memory: 16G    # Increased from 8G
        reservations:
          cpus: '4'      # Increased from 2
          memory: 8G     # Increased from 4G
```

### Vertical Scaling (ECS)

Update task definition with more resources:

```json
{
  "cpu": "4096",     // Increased from 2048
  "memory": "16384"  // Increased from 8192
}
```

### Horizontal Scaling (Docker Compose)

Use Docker Swarm for multiple replicas:

```bash
# Initialize swarm
docker swarm init

# Deploy stack with 5 replicas
docker stack deploy -c docker-compose.yml valhalla

# Scale service
docker service scale valhalla_valhalla-jni=10
```

### Horizontal Scaling (ECS)

Update desired task count:

```bash
# Manual scaling
aws ecs update-service \
    --cluster valhalla-production \
    --service valhalla-jni-service \
    --desired-count 10

# Auto-scaling (configured in ECS section above)
# Scales between 3-20 tasks based on CPU/memory metrics
```

### Regional Scaling

Deploy separate ECS services per region:

```bash
# Singapore service
aws ecs create-service \
    --cluster valhalla-production \
    --service-name valhalla-jni-singapore \
    --task-definition valhalla-jni:1 \
    --desired-count 3

# Thailand service
aws ecs create-service \
    --cluster valhalla-production \
    --service-name valhalla-jni-thailand \
    --task-definition valhalla-jni-thailand:1 \
    --desired-count 5

# Use ALB target groups for region routing
```

---

## 🔒 Security Hardening

### Container Security

```dockerfile
# Run as non-root (already in Dockerfile.prod)
USER 1000:1000

# Read-only root filesystem
docker run --read-only --tmpfs /tmp valhalla-jni:latest

# Drop capabilities
docker run --cap-drop=ALL valhalla-jni:latest

# No privileged mode
docker run --security-opt=no-new-privileges:true valhalla-jni:latest
```

### ECS Security

**IAM Task Role** (least privilege):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:ClientRead",
        "elasticfilesystem:ClientMount"
      ],
      "Resource": "arn:aws:elasticfilesystem:us-east-1:YOUR_ACCOUNT:file-system/fs-XXXXXXXX"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:us-east-1:YOUR_ACCOUNT:log-group:/ecs/valhalla-jni:*"
    }
  ]
}
```

### VPC Security Groups

```bash
# Create security group for ECS tasks
aws ec2 create-security-group \
    --group-name valhalla-jni-sg \
    --description "Security group for Valhalla JNI ECS tasks" \
    --vpc-id vpc-xxx

# Allow inbound from ALB only
aws ec2 authorize-security-group-ingress \
    --group-id sg-xxx \
    --protocol tcp \
    --port 8080 \
    --source-group sg-alb

# Allow outbound to EFS
aws ec2 authorize-security-group-egress \
    --group-id sg-xxx \
    --protocol tcp \
    --port 2049 \
    --destination-group sg-efs
```

### Secrets Management

**Use AWS Secrets Manager**:

```bash
# Store secret
aws secretsmanager create-secret \
    --name valhalla/prod/api-key \
    --secret-string "YOUR_API_KEY"

# Reference in ECS task definition
{
  "secrets": [
    {
      "name": "API_KEY",
      "valueFrom": "arn:aws:secretsmanager:us-east-1:YOUR_ACCOUNT:secret:valhalla/prod/api-key"
    }
  ]
}
```

### Network Encryption

```bash
# Enable EFS encryption in transit (already configured in ECS task definition)
"transitEncryption": "ENABLED"

# Use HTTPS/TLS on ALB
aws elbv2 create-listener \
    --load-balancer-arn arn:aws:elasticloadbalancing:... \
    --protocol HTTPS \
    --port 443 \
    --certificates CertificateArn=arn:aws:acm:...
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

**Recovery Steps (ECS)**:
```bash
# 1. Restore tiles to EFS
aws s3 sync s3://backups/valhalla/tiles/ /mnt/efs/tiles/

# 2. Redeploy ECS service
aws ecs update-service \
    --cluster valhalla-production \
    --service valhalla-jni-service \
    --force-new-deployment

# 3. Verify health
aws ecs describe-services \
    --cluster valhalla-production \
    --services valhalla-jni-service

curl https://routing.example.com/health
```

**Recovery Steps (Docker)**:
```bash
# 1. Restore tiles from backup
aws s3 sync s3://backups/valhalla/tiles/ /mnt/valhalla/tiles/

# 2. Redeploy containers
docker-compose down
docker-compose pull
docker-compose up -d

# 3. Verify health
docker-compose ps
curl http://localhost:8080/health
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

### High Memory Usage (ECS)

```bash
# Check ECS task metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/ECS \
    --metric-name MemoryUtilization \
    --dimensions Name=ServiceName,Value=valhalla-jni-service \
                 Name=ClusterName,Value=valhalla-production \
    --start-time 2026-02-25T00:00:00Z \
    --end-time 2026-02-25T23:59:59Z \
    --period 300 \
    --statistics Average

# Get task ARN and exec into container
TASK_ARN=$(aws ecs list-tasks --cluster valhalla-production --service-name valhalla-jni-service --query 'taskArns[0]' --output text)

aws ecs execute-command \
    --cluster valhalla-production \
    --task $TASK_ARN \
    --container valhalla-jni \
    --interactive \
    --command "jmap -dump:live,format=b,file=/tmp/heap.hprof \$(pgrep java)"

# Analyze with MAT or VisualVM
```

### High Memory Usage (Docker)

```bash
# Check container stats
docker stats valhalla-jni

# Heap dump
docker exec -it valhalla-jni \
    jmap -dump:live,format=b,file=/tmp/heap.hprof $(docker exec valhalla-jni pgrep java)

# Copy heap dump out
docker cp valhalla-jni:/tmp/heap.hprof ./heap.hprof

# Analyze with MAT or VisualVM
```

### High CPU Usage (ECS)

```bash
# Check CPU metrics
aws cloudwatch get-metric-statistics \
    --namespace AWS/ECS \
    --metric-name CPUUtilization \
    --dimensions Name=ServiceName,Value=valhalla-jni-service \
    --start-time 2026-02-25T00:00:00Z \
    --end-time 2026-02-25T23:59:59Z \
    --period 300 \
    --statistics Average

# Profile with JFR
aws ecs execute-command \
    --cluster valhalla-production \
    --task $TASK_ARN \
    --container valhalla-jni \
    --interactive \
    --command "jcmd \$(pgrep java) JFR.start duration=60s filename=/tmp/profile.jfr"
```

### High CPU Usage (Docker)

```bash
# Check CPU usage
docker stats valhalla-jni

# Profile with JFR
docker exec -it valhalla-jni \
    jcmd $(docker exec valhalla-jni pgrep java) JFR.start duration=60s filename=/tmp/profile.jfr

# Copy profile out
docker cp valhalla-jni:/tmp/profile.jfr ./profile.jfr

# Analyze with JMC
```

### Slow Routes (ECS)

```bash
# Check logs
aws logs tail /ecs/valhalla-jni --follow --filter-pattern "route calculation"

# Enable debug logging (update task definition environment variable)
# LOG_LEVEL=DEBUG

# Check tile access
aws efs describe-file-systems --file-system-id fs-XXXXXXXX
```

### Slow Routes (Docker)

```bash
# Check logs
docker logs -f valhalla-jni | grep "route calculation"

# Enable debug logging
docker-compose exec valhalla-jni \
    /bin/sh -c 'export LOG_LEVEL=DEBUG && java -jar /app/your-app.jar'

# Check tile mount
docker exec valhalla-jni ls -lh /var/valhalla/tiles/
```

### Container Won't Start (Docker)

```bash
# Check logs
docker logs valhalla-jni

# Common issues:
# 1. Tiles not mounted: Check volume mount
docker inspect valhalla-jni | grep Mounts -A 10

# 2. Memory limit: Increase in docker-compose.yml
# 3. Port conflict: Check port 8080
netstat -tuln | grep 8080
```

### ECS Tasks Failing

```bash
# Check task stopped reason
aws ecs describe-tasks \
    --cluster valhalla-production \
    --tasks $TASK_ARN \
    --query 'tasks[0].stoppedReason'

# Check logs
aws logs tail /ecs/valhalla-jni --follow

# Common issues:
# 1. EFS mount failed: Check security groups
# 2. Health check failed: Verify /health endpoint
# 3. Resource limits: Increase CPU/memory in task definition
```

---

## ✅ Production Checklist

Before going live:

- [ ] Docker image built and tested (`docker/Dockerfile.prod`)
- [ ] Image pushed to container registry (ECR/Docker Hub)
- [ ] Tile data uploaded to shared storage (EFS/S3/NFS)
- [ ] Configuration validated (`config/regions/regions.json`)
- [ ] Environment variables configured (`VALHALLA_TILE_DIR`, `JAVA_OPTS`)
- [ ] Health checks passing (`/health` endpoint)
- [ ] Monitoring configured (CloudWatch/Prometheus)
- [ ] Alerting rules created (high CPU/memory/error rate)
- [ ] Auto-scaling configured (ECS auto-scaling or Docker Swarm)
- [ ] Load balancer configured (ALB with health checks)
- [ ] Security groups configured (allow only necessary traffic)
- [ ] IAM roles configured (least privilege)
- [ ] Disaster recovery plan documented
- [ ] Load testing completed (verify throughput targets)
- [ ] Security hardening applied (non-root user, read-only filesystem)
- [ ] Backup strategy implemented (S3 tile backups)
- [ ] Documentation reviewed

**Ready for production! 🚀**

---

## 📚 Additional Resources

- **Quick Start**: See [QUICKSTART.md](QUICKSTART.md)
- **Development**: See [DEVELOPMENT.md](DEVELOPMENT.md)
- **Adding Regions**: See [ADDING_REGIONS.md](../regions/ADDING_REGIONS.md)
- **Docker Best Practices**: https://docs.docker.com/develop/dev-best-practices/
- **AWS ECS Best Practices**: https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/intro.html
- **AWS EFS Best Practices**: https://docs.aws.amazon.com/efs/latest/ug/performance.html

---

**Questions?** Reach out to the DevOps team or check the troubleshooting section above.
