# Vertical Pod Autoscaler (VPA) Manifests for Mosuon

This directory contains Vertical Pod Autoscaler installation manifests and configurations.

## Installation

### Option 1: Using the Install Script (Recommended)

```bash
# Install VPA components
kubectl apply -f https://github.com/kubernetes/autoscaler/releases/download/vertical-pod-autoscaler-1.1.2/vpa-v1.1.2.yaml

# Or use the provisioning workflow which handles this automatically
```

### Option 2: Manual Installation

```bash
# Clone the autoscaler repo
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler

# Install VPA
./hack/vpa-up.sh
```

## Verification

Check VPA components are running:

```bash
kubectl get pods -n kube-system | grep vpa
```

Expected output:
```
vpa-admission-controller-xxx   1/1     Running
vpa-recommender-xxx           1/1     Running
vpa-updater-xxx               1/1     Running
```

## VPA Modes

VPA can operate in three modes:

| Mode | Description | Use Case |
|------|-------------|----------|
| **"Off"** | Generates recommendations only | Safe for production observation |
| **"Initial"** | Applies recommendations at pod creation | Low-disruption updates |
| **"Recreate"** | Recreates pods to apply recommendations | Full automatic optimization |
| **"Auto"** | Same as Recreate (deprecated name) | Legacy compatibility |

## Configuration in values.yaml

Enable VPA in your application's values.yaml:

```yaml
verticalPodAutoscaling:
  enabled: true
  updateMode: "Off"           # Start with recommendation mode
  minCPU: 100m
  maxCPU: 2000m
  minMemory: 256Mi
  maxMemory: 2Gi
  controlledResources: ["cpu", "memory"]
  controlledValues: RequestsAndLimits
  recommendationMode: true    # Forces "Off" mode for safety
```

## Viewing Recommendations

```bash
# Get VPA recommendations for game-stats-api
kubectl describe vpa game-stats-api -n mosuon

# Get all VPA resources
kubectl get vpa -A
```

## Best Practices for Mosuon

1. **Start with "Off" mode** - Observe recommendations for 24-48 hours before enabling auto-updates
2. **Don't mix VPA and HPA on same metrics** - Use HPA for CPU/memory scaling, VPA for resource optimization
3. **Set appropriate min/max bounds** - Prevent over-provisioning or under-provisioning
4. **Monitor after enabling** - Watch for unexpected pod restarts

## VPA vs HPA

| Feature | HPA | VPA |
|---------|-----|-----|
| Scales | Number of pods | Pod resources |
| Trigger | CPU/Memory utilization | Resource usage patterns |
| Use case | Handle load spikes | Right-size containers |
| Disruption | None (adds pods) | Pod restart required |

### Recommended Strategy for Mosuon

- **game-stats-api**: HPA for scaling (1-3 replicas), VPA in "Off" mode for recommendations
- **game-stats-ui**: HPA for scaling (1-3 replicas), VPA in "Off" mode for recommendations
- **metabase**: VPA only (single instance), "Off" mode initially

## Files

- `example-vpa.yaml` - Example VPA configurations for different use cases
- `../manifests/vpa/vpa-setup.yaml` - VPA installation and app-specific configs

## Documentation

- [Official VPA Documentation](https://github.com/kubernetes/autoscaler/tree/master/vertical-pod-autoscaler)
- [Mosuon Scaling Guide](../docs/scaling.md)
