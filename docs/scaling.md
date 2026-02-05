# Scaling & Auto-Scaling

Complete guide for manual and automatic scaling of applications on the Mosuon Kubernetes cluster.

## Scaling Strategies

### 1. Horizontal Pod Autoscaling (HPA)

**Scales**: Number of pod replicas
**Based on**: CPU, Memory, Custom metrics

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: game-stats-api
  namespace: mosuon
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: game-stats-api
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 75
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # Wait 5min before scaling down
      policies:
      - type: Percent
        value: 50
        periodSeconds: 60  # Scale down max 50% every minute
    scaleUp:
      stabilizationWindowSeconds: 0  # Scale up immediately
      policies:
      - type: Percent
        value: 100
        periodSeconds: 60  # Scale up max 100% every minute
```

### 2. Vertical Pod Autoscaling (VPA)

**Scales**: CPU and memory requests/limits
**Based on**: Historical usage

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: game-stats-api
  namespace: mosuon
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: game-stats-api
  updatePolicy:
    updateMode: "Auto"  # Auto, Recreate, Initial, Off
  resourcePolicy:
    containerPolicies:
    - containerName: game-stats-api
      minAllowed:
        cpu: 100m
        memory: 128Mi
      maxAllowed:
        cpu: 2
        memory: 2Gi
      controlledResources: ["cpu", "memory"]
```

**VPA Update Modes**:
- `Off`: Only provides recommendations
- `Initial`: Sets resources on pod creation only
- `Recreate`: Deletes and recreates pods with new resources
- `Auto`: Updates in-place (requires feature gate)

### 3. Cluster Autoscaling

**Scales**: Number of nodes
**Based on**: Pod scheduling failures

**Note**: Not applicable for single-node VPS. Requires cloud provider (GKE, EKS, AKS).

## HPA Implementation

### Prerequisites

```bash
# Install metrics-server
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify metrics-server
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -A
```

### Create HPA

#### Using kubectl

```bash
# CPU-based autoscaling
kubectl autoscale deployment game-stats-api \
  --namespace=mosuon \
  --cpu-percent=70 \
  --min=2 \
  --max=10

# Check HPA status
kubectl get hpa -n mosuon game-stats-api

# Describe HPA for details
kubectl describe hpa -n mosuon game-stats-api
```

#### Using YAML

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: game-stats-api
  namespace: mosuon
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: game-stats-api
  minReplicas: 2
  maxReplicas: 10
  metrics:
  # CPU utilization
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  
  # Memory utilization
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 75
  
  # Custom metric (requires prometheus-adapter)
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "1000"
```

### Scaling Behavior

**Scale Up**:
```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0  # No delay
    policies:
    - type: Percent
      value: 100  # Double pods
      periodSeconds: 60
    - type: Pods
      value: 4  # Or add 4 pods
      periodSeconds: 60
    selectPolicy: Max  # Choose whichever scales more
```

**Scale Down**:
```yaml
behavior:
  scaleDown:
    stabilizationWindowSeconds: 300  # Wait 5 minutes
    policies:
    - type: Percent
      value: 50  # Reduce by half
      periodSeconds: 60
    selectPolicy: Min  # Choose whichever scales less (more conservative)
```

## Custom Metrics with Prometheus Adapter

### Install Prometheus Adapter

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://prometheus-kube-prometheus-prometheus.monitoring.svc \
  --set prometheus.port=9090
```

### Configure Custom Metrics

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: adapter-config
  namespace: monitoring
data:
  config.yaml: |
    rules:
    - seriesQuery: 'http_requests_total{namespace="mosuon"}'
      resources:
        overrides:
          namespace: {resource: "namespace"}
          pod: {resource: "pod"}
      name:
        matches: "^(.*)_total"
        as: "${1}_per_second"
      metricsQuery: 'sum(rate(<<.Series>>{<<.LabelMatchers>>}[2m])) by (<<.GroupBy>>)'
```

### HPA with Custom Metric

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: game-stats-api
  namespace: mosuon
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: game-stats-api
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "100"  # Scale when RPS > 100 per pod
```

## KEDA (Kubernetes Event-Driven Autoscaling)

### Install KEDA

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda --namespace keda --create-namespace
```

### ScaledObject (KEDA)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: game-stats-api
  namespace: mosuon
spec:
  scaleTargetRef:
    name: game-stats-api
  minReplicaCount: 2
  maxReplicaCount: 10
  cooldownPeriod: 300  # Seconds to wait after last trigger
  triggers:
  # Prometheus trigger
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090
      metricName: http_requests_per_second
      threshold: "100"
      query: |
        sum(rate(http_requests_total{app="game-stats-api"}[2m]))
  
  # Redis list length trigger
  - type: redis
    metadata:
      address: redis-master.infra.svc.cluster.local:6379
      listName: task_queue
      listLength: "10"
  
  # Cron trigger (predictive scaling)
  - type: cron
    metadata:
      timezone: Africa/Nairobi
      start: 0 8 * * *  # Scale up at 8 AM
      end: 0 20 * * *   # Scale down at 8 PM
      desiredReplicas: "5"
```

## Manual Scaling

### Scale Deployment

```bash
# Scale to specific replica count
kubectl scale deployment game-stats-api -n mosuon --replicas=5

# Scale multiple deployments
kubectl scale deployment -n mosuon --all --replicas=3

# Scale ReplicaSet directly (not recommended)
kubectl scale rs game-stats-api-7d8c9f5b6 -n mosuon --replicas=3
```

### Scale StatefulSet

```bash
# Scale StatefulSet
kubectl scale statefulset postgresql -n infra --replicas=3

# Warning: StatefulSets scale one pod at a time
# Scaling down deletes pods in reverse order (pod-2, pod-1, pod-0)
```

## Load Testing

### Using Apache Bench

```bash
# 10000 requests, 100 concurrent
ab -n 10000 -c 100 https://api.stats.ultimatestats.co.ke/api/v1/matches
```

### Using k6

```javascript
// load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '2m', target: 100 },  // Ramp up to 100 users
    { duration: '5m', target: 100 },  // Stay at 100 users
    { duration: '2m', target: 200 },  // Ramp up to 200 users
    { duration: '5m', target: 200 },  // Stay at 200 users
    { duration: '2m', target: 0 },    // Ramp down to 0 users
  ],
};

export default function () {
  let res = http.get('https://api.stats.ultimatestats.co.ke/api/v1/matches');
  
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 500ms': (r) => r.timings.duration < 500,
  });
  
  sleep(1);
}
```

```bash
# Run load test
k6 run load-test.js

# Monitor HPA during test
watch -n 2 'kubectl get hpa -n mosuon'
```

### Using Locust

```python
# locustfile.py
from locust import HttpUser, task, between

class GameStatsUser(HttpUser):
    wait_time = between(1, 3)
    host = "https://api.stats.ultimatestats.co.ke"
    
    @task(3)
    def get_matches(self):
        self.client.get("/api/v1/matches")
    
    @task(2)
    def get_rankings(self):
        self.client.get("/api/v1/rankings")
    
    @task(1)
    def get_player(self):
        self.client.get("/api/v1/players/123")
```

```bash
# Run locust
locust -f locustfile.py --users 100 --spawn-rate 10
```

## Resource Quotas

Limit resource usage per namespace:

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: mosuon-quota
  namespace: mosuon
spec:
  hard:
    requests.cpu: "10"
    requests.memory: "20Gi"
    limits.cpu: "20"
    limits.memory: "40Gi"
    persistentvolumeclaims: "10"
    pods: "50"
```

Check quota usage:
```bash
kubectl describe resourcequota mosuon-quota -n mosuon
```

## LimitRange

Set default and min/max resource limits:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: mosuon-limits
  namespace: mosuon
spec:
  limits:
  - max:
      cpu: "2"
      memory: "2Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "256Mi"
    type: Container
```

## Monitoring Autoscaling

### Check HPA Metrics

```bash
# Get HPA status
kubectl get hpa -n mosuon

# Watch HPA in real-time
kubectl get hpa -n mosuon --watch

# Detailed HPA info
kubectl describe hpa game-stats-api -n mosuon

# View HPA events
kubectl get events -n mosuon --field-selector involvedObject.name=game-stats-api
```

### Prometheus Queries

```promql
# Current replica count
kube_deployment_status_replicas{deployment="game-stats-api"}

# Desired replica count (HPA target)
kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="game-stats-api"}

# CPU utilization
sum(rate(container_cpu_usage_seconds_total{namespace="mosuon",pod=~"game-stats-api.*"}[5m])) by (pod)
/
sum(kube_pod_container_resource_requests{namespace="mosuon",pod=~"game-stats-api.*",resource="cpu"}) by (pod)

# Memory utilization
sum(container_memory_usage_bytes{namespace="mosuon",pod=~"game-stats-api.*"}) by (pod)
/
sum(kube_pod_container_resource_limits{namespace="mosuon",pod=~"game-stats-api.*",resource="memory"}) by (pod)
```

### Grafana Dashboard

**Panels to include**:
1. Current vs Desired Replicas
2. CPU Utilization per Pod
3. Memory Utilization per Pod
4. Request Rate
5. Response Time (p95)
6. Scaling Events Timeline

## Best Practices

1. **Set Resource Requests/Limits**
   ```yaml
   resources:
     requests:
       cpu: 100m
       memory: 256Mi
     limits:
       cpu: 500m
       memory: 512Mi
   ```

2. **Minimum 2 Replicas for HA**
   ```yaml
   minReplicas: 2
   ```

3. **Gradual Scale Down**
   ```yaml
   behavior:
     scaleDown:
       stabilizationWindowSeconds: 300
   ```

4. **Monitor Before Autoscaling**
   - Run app for 1 week
   - Analyze resource usage patterns
   - Set thresholds based on real data

5. **Test Under Load**
   - Run load tests before production
   - Verify autoscaling triggers correctly
   - Check pod startup time

6. **Set PodDisruptionBudget**
   ```yaml
   apiVersion: policy/v1
   kind: PodDisruptionBudget
   metadata:
     name: game-stats-api-pdb
     namespace: mosuon
   spec:
     minAvailable: 1
     selector:
       matchLabels:
         app: game-stats-api
   ```

## Troubleshooting

### HPA Not Scaling

```bash
# Check metrics-server
kubectl top pods -n mosuon

# Check HPA conditions
kubectl describe hpa game-stats-api -n mosuon

# Check resource requests are set
kubectl get deployment game-stats-api -n mosuon -o yaml | grep -A 5 resources

# Check HPA events
kubectl get events -n mosuon | grep HorizontalPodAutoscaler
```

### Metrics Not Available

```bash
# Restart metrics-server
kubectl rollout restart deployment metrics-server -n kube-system

# Check metrics-server logs
kubectl logs -n kube-system -l k8s-app=metrics-server

# Verify kubelet metrics
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
kubectl get --raw /apis/metrics.k8s.io/v1beta1/pods
```

### Pods Not Scheduling (Resource Constraints)

```bash
# Check pod events
kubectl describe pod game-stats-api-xxx -n mosuon

# Check node resources
kubectl describe nodes

# Temporarily increase node resources or reduce pod requests
```

## Scaling Checklist

- [ ] Resource requests and limits defined
- [ ] metrics-server installed and working
- [ ] HPA created with appropriate thresholds
- [ ] PodDisruptionBudget configured
- [ ] Load testing performed
- [ ] Autoscaling behavior verified
- [ ] Monitoring and alerts configured
- [ ] Resource quotas set (if needed)
- [ ] Documentation updated with scaling strategy

## Cost Optimization

1. **Right-size resources** based on actual usage
2. **Scale to zero** for dev/staging (using KEDA cron)
3. **Use spot/preemptible instances** (cloud only)
4. **Set aggressive scale-down** for non-critical workloads
5. **Monitor idle resources** and adjust quotas

## Future Enhancements

- [ ] Predictive autoscaling (ML-based)
- [ ] Multi-metric HPA (CPU + custom metrics)
- [ ] KEDA for event-driven scaling
- [ ] Cluster autoscaling (if migrating to cloud)
- [ ] Cost monitoring and optimization dashboards
