# Kubernetes Deployment for Valhalla JNI

Complete Kubernetes deployment configuration for Valhalla JNI routing service.

## Quick Start

```bash
# 1. Create namespace
kubectl apply -f namespace.yaml

# 2. Create ConfigMaps
kubectl apply -f configmap.yaml

# 3. Create PersistentVolume and PVC for tiles
kubectl apply -f pv-tiles.yaml

# 4. Deploy application
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

# 5. Configure auto-scaling
kubectl apply -f hpa.yaml

# 6. Expose externally (optional)
kubectl apply -f ingress.yaml

# 7. Verify deployment
kubectl get all -n valhalla
kubectl get pods -n valhalla -w
```

## Files Overview

| File | Description |
|------|-------------|
| `namespace.yaml` | Kubernetes namespace for Valhalla |
| `configmap.yaml` | Configuration (environment vars, regions config) |
| `pv-tiles.yaml` | PersistentVolume for tile storage (NFS/EBS/EFS) |
| `deployment.yaml` | Main deployment with 3 replicas, resource limits, probes |
| `service.yaml` | ClusterIP service + headless service |
| `hpa.yaml` | HorizontalPodAutoscaler (3-20 pods, CPU/memory-based) |
| `ingress.yaml` | Nginx ingress with TLS, rate limiting |

## Prerequisites

1. **Kubernetes cluster** (1.23+)
2. **kubectl** configured
3. **Tile storage** (NFS server, AWS EBS/EFS, or similar)
4. **Docker registry** with Valhalla JNI image
5. **Ingress controller** (nginx-ingress, AWS ALB, etc.)
6. **cert-manager** (optional, for TLS certificates)

## Configuration

### 1. Update Tile Storage

Edit `pv-tiles.yaml`:

```yaml
nfs:
  server: YOUR_NFS_SERVER  # Replace with your NFS server
  path: /mnt/valhalla/tiles
```

**Or use AWS EBS/EFS** (see comments in `pv-tiles.yaml`).

### 2. Update Docker Image

Edit `deployment.yaml`:

```yaml
image: your-registry.example.com/valhalla-jni:latest  # Replace with your registry
```

### 3. Update Ingress Host

Edit `ingress.yaml`:

```yaml
host: routing.example.com  # Replace with your domain
```

### 4. Configure Resources

Edit `deployment.yaml` resources based on your workload:

```yaml
resources:
  requests:
    memory: "4Gi"   # Minimum memory
    cpu: "2000m"    # Minimum CPU (2 cores)
  limits:
    memory: "8Gi"   # Maximum memory
    cpu: "4000m"    # Maximum CPU (4 cores)
```

## Deployment Steps

### Step 1: Prepare Tile Storage

```bash
# Option A: NFS
# Ensure tiles are available on NFS server at /mnt/valhalla/tiles/

# Option B: AWS EBS
# Create EBS volume and attach to nodes
aws ec2 create-volume --size 100 --volume-type gp3 --availability-zone us-east-1a

# Option C: AWS EFS
# Create EFS filesystem
aws efs create-file-system --tags Key=Name,Value=valhalla-tiles
```

### Step 2: Build and Push Docker Image

```bash
# Build production image
docker build -f docker/Dockerfile.prod -t valhalla-jni:latest .

# Tag for registry
docker tag valhalla-jni:latest your-registry.example.com/valhalla-jni:latest

# Push to registry
docker push your-registry.example.com/valhalla-jni:latest
```

### Step 3: Deploy to Kubernetes

```bash
# Apply all manifests
kubectl apply -f namespace.yaml
kubectl apply -f configmap.yaml
kubectl apply -f pv-tiles.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f hpa.yaml
kubectl apply -f ingress.yaml

# Wait for pods to be ready
kubectl wait --for=condition=ready pod -l app=valhalla-jni -n valhalla --timeout=300s
```

### Step 4: Verify Deployment

```bash
# Check pods
kubectl get pods -n valhalla

# Check services
kubectl get svc -n valhalla

# Check HPA
kubectl get hpa -n valhalla

# Check ingress
kubectl get ingress -n valhalla

# Check logs
kubectl logs -f deployment/valhalla-jni -n valhalla
```

### Step 5: Test Routing

```bash
# Port-forward (for testing)
kubectl port-forward -n valhalla svc/valhalla-jni 8080:80

# Test health endpoint
curl http://localhost:8080/health

# Test route (adjust based on your API)
curl -X POST http://localhost:8080/route \
  -H "Content-Type: application/json" \
  -d '{
    "locations": [
      {"lat": 1.290270, "lon": 103.851959},
      {"lat": 1.352083, "lon": 103.819836}
    ],
    "costing": "auto"
  }'

# Or via ingress (if configured)
curl https://routing.example.com/health
```

## Scaling

### Manual Scaling

```bash
# Scale to 10 replicas
kubectl scale deployment valhalla-jni --replicas=10 -n valhalla

# Check status
kubectl get pods -n valhalla
```

### Auto-scaling (HPA)

HPA automatically scales based on:
- CPU utilization (target: 70%)
- Memory utilization (target: 80%)
- Custom metrics (if configured)

```bash
# Check HPA status
kubectl get hpa -n valhalla

# Watch scaling events
kubectl describe hpa valhalla-jni-hpa -n valhalla
```

## Monitoring

### Check Metrics

```bash
# Pod metrics
kubectl top pods -n valhalla

# Node metrics
kubectl top nodes

# HPA metrics
kubectl get hpa -n valhalla -w
```

### View Logs

```bash
# All pods
kubectl logs -f deployment/valhalla-jni -n valhalla

# Specific pod
kubectl logs -f <pod-name> -n valhalla

# Previous container (if crashed)
kubectl logs --previous <pod-name> -n valhalla
```

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod <pod-name> -n valhalla

# Common issues:
# 1. Image pull error: Check registry credentials
# 2. Resource limits: Increase memory/CPU
# 3. PVC not bound: Check PersistentVolume configuration
```

### Tiles Not Found

```bash
# Exec into pod
kubectl exec -it -n valhalla deployment/valhalla-jni -- bash

# Check tiles
ls -lh /var/valhalla/tiles/

# Check mount
df -h | grep valhalla
```

### High Memory Usage

```bash
# Check memory usage
kubectl top pods -n valhalla

# Increase memory limits in deployment.yaml
# Or reduce JVM heap size in configmap.yaml
```

## Updating Deployment

### Rolling Update

```bash
# Update image
kubectl set image deployment/valhalla-jni \
  valhalla-jni=your-registry.example.com/valhalla-jni:v2 \
  -n valhalla

# Watch rollout
kubectl rollout status deployment/valhalla-jni -n valhalla
```

### Rollback

```bash
# Rollback to previous version
kubectl rollout undo deployment/valhalla-jni -n valhalla

# Rollback to specific revision
kubectl rollout undo deployment/valhalla-jni --to-revision=2 -n valhalla
```

### Update Configuration

```bash
# Edit ConfigMap
kubectl edit configmap valhalla-config -n valhalla

# Restart pods to pick up changes
kubectl rollout restart deployment/valhalla-jni -n valhalla
```

## Cleanup

```bash
# Delete all resources
kubectl delete -f ingress.yaml
kubectl delete -f hpa.yaml
kubectl delete -f service.yaml
kubectl delete -f deployment.yaml
kubectl delete -f pv-tiles.yaml
kubectl delete -f configmap.yaml
kubectl delete -f namespace.yaml

# Or delete namespace (deletes everything)
kubectl delete namespace valhalla
```

## Security Best Practices

1. **Run as non-root**: Already configured in deployment.yaml
2. **Read-only root filesystem**: Uncomment in deployment.yaml if needed
3. **Network policies**: Restrict pod-to-pod communication
4. **RBAC**: Create ServiceAccount with minimal permissions
5. **Secrets management**: Use Kubernetes Secrets or external vaults
6. **Image scanning**: Scan Docker images for vulnerabilities
7. **Resource limits**: Always set resource limits to prevent resource exhaustion

## Performance Tuning

1. **CPU requests**: Set to 2-4 cores per pod
2. **Memory limits**: 4-8GB per pod (depends on tile size)
3. **HPA thresholds**: Tune based on actual load patterns
4. **JVM heap**: Set to 50-70% of container memory limit
5. **Node affinity**: Use nodes with SSD for better tile I/O
6. **Pod anti-affinity**: Spread pods across nodes for HA

## Additional Resources

- [Kubernetes Best Practices](https://kubernetes.io/docs/concepts/configuration/overview/)
- [HPA Documentation](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Ingress Documentation](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Production Guide](../PRODUCTION.md)
