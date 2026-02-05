# Monitoring & Observability

Complete guide for monitoring the Mosuon Kubernetes cluster with Prometheus, Grafana, and logging.

## Architecture Overview

```
Applications → Prometheus → Grafana → Alerts
     ↓            ↓
  Logs →    Loki/ElasticSearch
     ↓
  Traces →  Jaeger/Tempo
```

## Prometheus Stack Installation

### Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.retention=30d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=20Gi \
  --set grafana.adminPassword=changeme \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=10Gi
```

### Components Installed

- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Alertmanager**: Alert routing and notifications
- **Node Exporter**: Node-level metrics
- **Kube State Metrics**: Kubernetes object metrics
- **Prometheus Operator**: Manages Prometheus instances

## Exposing Grafana

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - grafana.ultimatestats.co.ke
      secretName: grafana-tls
  rules:
    - host: grafana.ultimatestats.co.ke
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: prometheus-grafana
                port:
                  number: 80
```

## Application Metrics

### Go/Chi Backend

```go
// metrics.go
package main

import (
    "github.com/prometheus/client_golang/prometheus"
    "github.com/prometheus/client_golang/prometheus/promauto"
    "github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
    httpRequestsTotal = promauto.NewCounterVec(
        prometheus.CounterOpts{
            Name: "http_requests_total",
            Help: "Total number of HTTP requests",
        },
        []string{"method", "endpoint", "status"},
    )
    
    httpRequestDuration = promauto.NewHistogramVec(
        prometheus.HistogramOpts{
            Name:    "http_request_duration_seconds",
            Help:    "HTTP request duration in seconds",
            Buckets: prometheus.DefBuckets,
        },
        []string{"method", "endpoint"},
    )
    
    dbConnectionPool = promauto.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "db_connection_pool",
            Help: "Database connection pool stats",
        },
        []string{"state"},  // idle, inuse, open
    )
)

// Middleware to record metrics
func metricsMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        start := time.Now()
        
        // Create response writer wrapper to capture status code
        rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
        
        next.ServeHTTP(rw, r)
        
        duration := time.Since(start).Seconds()
        
        httpRequestsTotal.WithLabelValues(
            r.Method,
            r.URL.Path,
            strconv.Itoa(rw.statusCode),
        ).Inc()
        
        httpRequestDuration.WithLabelValues(
            r.Method,
            r.URL.Path,
        ).Observe(duration)
    })
}

// Update DB metrics periodically
func updateDBMetrics(db *sql.DB) {
    go func() {
        for {
            stats := db.Stats()
            dbConnectionPool.WithLabelValues("idle").Set(float64(stats.Idle))
            dbConnectionPool.WithLabelValues("inuse").Set(float64(stats.InUse))
            dbConnectionPool.WithLabelValues("open").Set(float64(stats.OpenConnections))
            time.Sleep(15 * time.Second)
        }
    }()
}

func main() {
    r := chi.NewRouter()
    r.Use(metricsMiddleware)
    
    // Expose metrics endpoint
    r.Handle("/metrics", promhttp.Handler())
    
    updateDBMetrics(db)
    
    http.ListenAndServe(":4000", r)
}
```

### ServiceMonitor CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: game-stats-api
  namespace: mosuon
  labels:
    app: game-stats-api
    prometheus: kube-prometheus
spec:
  selector:
    matchLabels:
      app: game-stats-api
  endpoints:
  - port: http
    path: /metrics
    interval: 30s
    scrapeTimeout: 10s
```

## Key Metrics to Monitor

### Application Metrics

```promql
# Request rate
rate(http_requests_total[5m])

# Error rate
rate(http_requests_total{status=~"5.."}[5m])

# Request duration (p95)
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# Database connection pool
db_connection_pool{state="inuse"} / db_connection_pool{state="open"} * 100
```

### Kubernetes Metrics

```promql
# Pod CPU usage
rate(container_cpu_usage_seconds_total{namespace="mosuon"}[5m])

# Pod memory usage
container_memory_usage_bytes{namespace="mosuon"}

# Pod restart count
kube_pod_container_status_restarts_total{namespace="mosuon"}

# Deployment replicas
kube_deployment_status_replicas_available{namespace="mosuon"}
```

### Infrastructure Metrics

```promql
# Node CPU usage
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# Node memory usage
(1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100

# Disk usage
100 - ((node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100)

# Network traffic
rate(node_network_receive_bytes_total[5m])
rate(node_network_transmit_bytes_total[5m])
```

## Grafana Dashboards

### Import Pre-built Dashboards

```bash
# Kubernetes cluster monitoring
Dashboard ID: 15757

# NGINX Ingress Controller
Dashboard ID: 9614

# PostgreSQL
Dashboard ID: 9628

# Redis
Dashboard ID: 11835

# Node Exporter
Dashboard ID: 1860
```

### Custom Dashboard (JSON)

```json
{
  "dashboard": {
    "title": "Game Stats Application",
    "panels": [
      {
        "title": "Request Rate",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{app=\"game-stats-api\"}[5m])) by (endpoint)"
          }
        ],
        "type": "graph"
      },
      {
        "title": "Error Rate",
        "targets": [
          {
            "expr": "sum(rate(http_requests_total{app=\"game-stats-api\",status=~\"5..\"}[5m])) / sum(rate(http_requests_total{app=\"game-stats-api\"}[5m])) * 100"
          }
        ],
        "type": "singlestat",
        "thresholds": "1,5"
      }
    ]
  }
}
```

## Alerting with Alertmanager

### PrometheusRule CRD

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: game-stats-alerts
  namespace: mosuon
  labels:
    prometheus: kube-prometheus
spec:
  groups:
  - name: game-stats-api
    interval: 30s
    rules:
    - alert: HighErrorRate
      expr: |
        sum(rate(http_requests_total{app="game-stats-api",status=~"5.."}[5m]))
        /
        sum(rate(http_requests_total{app="game-stats-api"}[5m]))
        > 0.05
      for: 5m
      labels:
        severity: warning
        app: game-stats-api
      annotations:
        summary: "High error rate for game-stats-api"
        description: "Error rate is {{ $value | humanizePercentage }} over the last 5 minutes"
    
    - alert: PodNotReady
      expr: kube_pod_status_phase{namespace="mosuon",phase!="Running"} > 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ $labels.pod }} not running"
        description: "Pod in namespace {{ $labels.namespace }} is in {{ $labels.phase }} state"
    
    - alert: HighMemoryUsage
      expr: |
        container_memory_usage_bytes{namespace="mosuon",pod=~"game-stats-api.*"}
        /
        container_spec_memory_limit_bytes{namespace="mosuon",pod=~"game-stats-api.*"}
        > 0.9
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "High memory usage for {{ $labels.pod }}"
        description: "Memory usage is {{ $value | humanizePercentage }}"
    
    - alert: DatabaseConnectionPoolExhausted
      expr: db_connection_pool{state="inuse"} / db_connection_pool{state="open"} > 0.9
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Database connection pool nearly exhausted"
        description: "{{ $value | humanizePercentage }} of connections in use"
```

### Alertmanager Configuration

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-prometheus-kube-prometheus-alertmanager
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
      
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'slack'
      routes:
      - match:
          severity: critical
        receiver: 'slack-critical'
        continue: true
      - match:
          severity: warning
        receiver: 'slack'
    
    receivers:
    - name: 'slack'
      slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
        channel: '#alerts'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
    
    - name: 'slack-critical'
      slack_configs:
      - api_url: 'https://hooks.slack.com/services/YOUR/WEBHOOK/URL'
        channel: '#critical-alerts'
        title: '🚨 CRITICAL: {{ .GroupLabels.alertname }}'
        text: '{{ range .Alerts }}{{ .Annotations.description }}{{ end }}'
    
    inhibit_rules:
    - source_match:
        severity: 'critical'
      target_match:
        severity: 'warning'
      equal: ['alertname']
```

## Logging

### Structured Logging (Go)

```go
import "github.com/rs/zerolog/log"

func main() {
    log.Info().
        Str("service", "game-stats-api").
        Str("version", "1.0.0").
        Msg("Service started")
    
    log.Error().
        Err(err).
        Str("user_id", "123").
        Str("action", "create_match").
        Msg("Failed to create match")
}
```

### Log Aggregation Options

#### Option 1: Loki (Recommended)

```bash
# Install Loki stack
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  --namespace monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set loki.persistence.enabled=true \
  --set loki.persistence.size=10Gi
```

**Grafana Data Source**:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: monitoring
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki:3100
      isDefault: false
```

#### Option 2: Elasticsearch + Fluentd + Kibana (EFK)

```bash
# Install Elasticsearch
helm install elasticsearch elastic/elasticsearch \
  --namespace logging \
  --create-namespace \
  --set replicas=1 \
  --set volumeClaimTemplate.resources.requests.storage=20Gi

# Install Kibana
helm install kibana elastic/kibana \
  --namespace logging \
  --set elasticsearchHosts=http://elasticsearch-master:9200

# Install Fluentd
helm install fluentd fluent/fluentd \
  --namespace logging
```

### Querying Logs

**Loki (LogQL)**:
```logql
# All logs from game-stats-api
{namespace="mosuon", app="game-stats-api"}

# Error logs only
{namespace="mosuon", app="game-stats-api"} |= "error"

# Logs for specific user
{namespace="mosuon", app="game-stats-api"} | json | user_id="123"

# Rate of errors
rate({namespace="mosuon", app="game-stats-api"} |= "error" [5m])
```

## Distributed Tracing

### Jaeger Installation

```bash
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm install jaeger jaegertracing/jaeger \
  --namespace monitoring \
  --set provisionDataStore.cassandra=false \
  --set allInOne.enabled=true \
  --set storage.type=memory
```

### OpenTelemetry Instrumentation (Go)

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/jaeger"
    "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer() {
    exporter, _ := jaeger.New(jaeger.WithCollectorEndpoint(
        jaeger.WithEndpoint("http://jaeger:14268/api/traces"),
    ))
    
    tp := trace.NewTracerProvider(
        trace.WithBatcher(exporter),
        trace.WithResource(resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceNameKey.String("game-stats-api"),
        )),
    )
    
    otel.SetTracerProvider(tp)
}

func handler(w http.ResponseWriter, r *http.Request) {
    ctx := r.Context()
    tr := otel.Tracer("game-stats-api")
    
    ctx, span := tr.Start(ctx, "handler")
    defer span.End()
    
    // Your code here
}
```

## Cost Optimization

### Retention Policies

```yaml
# Prometheus retention
prometheus:
  prometheusSpec:
    retention: 30d  # Keep metrics for 30 days
    retentionSize: "20GB"
```

### Metric Relabeling (Drop Unused Metrics)

```yaml
prometheus:
  prometheusSpec:
    metricRelabelings:
    - sourceLabels: [__name__]
      regex: 'etcd_.*'
      action: drop  # Drop all etcd metrics
```

### Sampling (Reduce Cardinality)

```yaml
# Sample 10% of requests
- alert: HighRequestRate
  expr: rate(http_requests_total[5m]) * 0.1  # Sample 10%
```

## Monitoring Checklist

- [ ] Prometheus installed and scraping metrics
- [ ] Grafana dashboards created
- [ ] Alertmanager configured with Slack/email
- [ ] PrometheusRules defined for critical alerts
- [ ] Application metrics exposed (`/metrics` endpoint)
- [ ] ServiceMonitors created for all apps
- [ ] Logging solution deployed (Loki/EFK)
- [ ] Distributed tracing enabled (optional)
- [ ] Retention policies configured
- [ ] Backup and restore tested
- [ ] Runbook created for common alerts

## Troubleshooting

### Prometheus Not Scraping

```bash
# Check ServiceMonitor
kubectl get servicemonitor -n mosuon

# Check Prometheus targets
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Visit http://localhost:9090/targets

# Check service labels match ServiceMonitor selector
kubectl get svc -n mosuon game-stats-api -o yaml
```

### High Cardinality

```bash
# Find high cardinality metrics
curl http://prometheus:9090/api/v1/label/__name__/values | jq '.data | length'

# Check metric series count
curl 'http://prometheus:9090/api/v1/query?query=count({__name__=~".+"})'
```

### Grafana Can't Connect to Prometheus

```bash
# Check data source configuration
kubectl get cm -n monitoring grafana-datasources -o yaml

# Test connectivity from Grafana pod
kubectl exec -n monitoring grafana-xxx -- curl http://prometheus-kube-prometheus-prometheus:9090
```
