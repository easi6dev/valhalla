# Docker Example

Containerized Valhalla routing service with external tile mounting.

## Build

```bash
# From project root
docker build -t valhalla-routing:latest -f examples/docker-example/Dockerfile .
```

## Run

### Option 1: Docker Run

```bash
docker run -d \
  --name valhalla-routing \
  -e VALHALLA_TILES_DIR=/tiles \
  -v /host/path/to/tiles/singapore:/tiles:ro \
  -p 8080:8080 \
  valhalla-routing:latest
```

### Option 2: Docker Compose

**Edit docker-compose.yml** to set your tile path:
```yaml
volumes:
  - /your/path/to/tiles/singapore:/tiles:ro
```

**Start services:**
```bash
docker-compose up -d

# Check logs
docker-compose logs -f valhalla-routing

# Check health
docker-compose ps
```

## Multiple Regions

Run multiple containers for different regions:

```bash
# Singapore
docker run -d --name singapore \
  -v /tiles/singapore:/tiles:ro \
  -p 8081:8080 \
  valhalla-routing:latest

# Thailand
docker run -d --name thailand \
  -v /tiles/thailand:/tiles:ro \
  -p 8082:8080 \
  valhalla-routing:latest
```

## Health Check

```bash
# Check if service is healthy
docker exec valhalla-routing java -cp /app/routing-service.jar HealthCheck
echo $?  # 0 = healthy, 1 = unhealthy

# Docker health status
docker inspect --format='{{.State.Health.Status}}' valhalla-routing
```

## Logs

```bash
# View logs
docker logs -f valhalla-routing

# Last 100 lines
docker logs --tail 100 valhalla-routing
```

## Stop and Remove

```bash
# Stop
docker stop valhalla-routing

# Remove
docker rm valhalla-routing

# Or with compose
docker-compose down
```

## Kubernetes Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: valhalla-routing
spec:
  replicas: 3
  selector:
    matchLabels:
      app: valhalla-routing
  template:
    metadata:
      labels:
        app: valhalla-routing
    spec:
      containers:
      - name: valhalla
        image: valhalla-routing:latest
        env:
        - name: VALHALLA_TILES_DIR
          value: "/tiles"
        - name: JAVA_OPTS
          value: "-Xmx2g -Xms512m"
        volumeMounts:
        - name: tiles
          mountPath: /tiles
          readOnly: true
        ports:
        - containerPort: 8080
        livenessProbe:
          exec:
            command:
            - java
            - -cp
            - /app/routing-service.jar
            - HealthCheck
          initialDelaySeconds: 10
          periodSeconds: 30
        readinessProbe:
          exec:
            command:
            - java
            - -cp
            - /app/routing-service.jar
            - HealthCheck
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: tiles
        persistentVolumeClaim:
          claimName: valhalla-tiles-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: valhalla-routing-service
spec:
  selector:
    app: valhalla-routing
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
```

## Production Notes

1. **Use proper HTTP framework** (Ktor, Spring Boot, Micronaut)
2. **Add authentication/authorization**
3. **Implement rate limiting**
4. **Set up monitoring** (Prometheus, Grafana)
5. **Use read-only file systems**
6. **Configure resource limits**
7. **Set up log aggregation**
8. **Implement graceful shutdown**
