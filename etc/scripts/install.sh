#!/usr/bin/env bash

# Installs istio, OLM and all knative operators on minishift

# WARNING: it totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion. 

KNATIVE_SERVING_VERSION=v0.2.2
KNATIVE_BUILD_VERSION=v0.2.0
KNATIVE_EVENTING_VERSION=v0.2.0

set -x

if minishift status | grep "Minishift:  Running" >/dev/null; then
  echo "A running minishift was detected. Please stop it before running this script."
  exit 1
fi

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && exit -1
  done
}

# Waits for all pods in the given namespace to complete successfully.
function wait_for_all_pods {
  timeout 300 "oc get pods -n $1 2>&1 | grep -v -E '(Running|Completed|STATUS)'"
}

DIR=$(cd $(dirname "$0") && pwd)
REPO_DIR=$DIR/.repos

rm -rf "$REPO_DIR"
mkdir -p "$REPO_DIR"

# blow away everything first
minishift profile delete knative --force

# configure knative profile
minishift profile set knative
minishift config set openshift-version v3.11.0
minishift config set memory 10GB
minishift config set cpus 4
minishift config set disk-size 50g
minishift config set image-caching true
minishift addons enable admin-user

# Start minishift
minishift start

eval "$(minishift oc-env)"
"$DIR/prep-knative.sh"

# istio
git clone https://github.com/minishift/minishift-addons "$REPO_DIR/minishift-addons"
minishift addon install "$REPO_DIR/minishift-addons/add-ons/istio"
until minishift addon apply istio; do sleep 1; done
timeout 900 'oc get pods -n istio-system && [[ $(oc get pods -n istio-system | grep openshift-ansible-istio-installer | grep -c Completed) -eq 0 ]]'

# Disable mTLS in istio
oc delete MeshPolicy default
oc delete DestinationRule default -n istio-system

# Scale down unused services deployed by the istio addon
oc scale -n istio-system --replicas=0 deployment/grafana
oc scale -n istio-system --replicas=0 deployment/jaeger-collector
oc scale -n istio-system --replicas=0 deployment/jaeger-query
oc scale -n istio-system --replicas=0 statefulset/elasticsearch

# Set up Prometheus scrape configurations
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    app: prometheus
    chart: prometheus-1.0.1
    heritage: Tiller
    maistra-version: 0.2.0
    release: istio-1.0.2
  name: prometheus
  namespace: istio-system
data:
  prometheus.yml: |-
    global:
      scrape_interval: 30s
      scrape_timeout: 10s
      evaluation_interval: 30s
    scrape_configs:
    - job_name: 'istio-mesh'
    # Override the global default and scrape targets from this job every 5 seconds.
      scrape_interval: 5s

      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system

      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-telemetry;prometheus

    - job_name: 'envoy'
      # Override the global default and scrape targets from this job every 5 seconds.
      scrape_interval: 5s
      # metrics_path defaults to '/metrics'
      # scheme defaults to 'http'.

      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system

      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-statsd-prom-bridge;statsd-prom

    - job_name: 'istio-policy'
      # Override the global default and scrape targets from this job every 5 seconds.
      scrape_interval: 5s
      # metrics_path defaults to '/metrics'
      # scheme defaults to 'http'.

      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system


      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-policy;http-monitoring

    - job_name: 'istio-telemetry'
      # Override the global default and scrape targets from this job every 5 seconds.
      scrape_interval: 5s
      # metrics_path defaults to '/metrics'
      # scheme defaults to 'http'.

      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system

      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-telemetry;http-monitoring

    - job_name: 'pilot'
       # Override the global default and scrape targets from this job every 5 seconds.
      scrape_interval: 5s
      # metrics_path defaults to '/metrics'
      # scheme defaults to 'http'.

      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system

      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-pilot;http-monitoring

    - job_name: 'galley'
      # Override the global default and scrape targets from this job every 5 seconds.
      scrape_interval: 5s
      # metrics_path defaults to '/metrics'
      # scheme defaults to 'http'.

      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - istio-system

      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: istio-galley;http-monitoring

    # scrape config for API servers
    - job_name: 'kubernetes-apiservers'
      kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
          - default
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
        action: keep
        regex: kubernetes;https

    # scrape config for nodes (kubelet)
    - job_name: 'kubernetes-nodes'
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics

    # Scrape config for Kubelet cAdvisor.
    #
    # This is required for Kubernetes 1.7.3 and later, where cAdvisor metrics
    # (those whose names begin with 'container_') have been removed from the
    # Kubelet metrics endpoint.  This job scrapes the cAdvisor endpoint to
    # retrieve those metrics.
    #
    # In Kubernetes 1.7.0-1.7.2, these metrics are only exposed on the cAdvisor
    # HTTP endpoint; use "replacement: /api/v1/nodes/${1}:4194/proxy/metrics"
    # in that case (and ensure cAdvisor's HTTP server hasn't been disabled with
    # the --cadvisor-port=0 Kubelet flag).
    #
    # This job is not necessary and should be removed in Kubernetes 1.6 and
    # earlier versions, or it will cause the metrics to be scraped twice.
    - job_name: 'kubernetes-cadvisor'
      scheme: https
      tls_config:
        ca_file: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
      bearer_token_file: /var/run/secrets/kubernetes.io/serviceaccount/token
      kubernetes_sd_configs:
      - role: node
      relabel_configs:
      - action: labelmap
        regex: __meta_kubernetes_node_label_(.+)
      - target_label: __address__
        replacement: kubernetes.default.svc:443
      - source_labels: [__meta_kubernetes_node_name]
        regex: (.+)
        target_label: __metrics_path__
        replacement: /api/v1/nodes/${1}/proxy/metrics/cadvisor

    # scrape config for service endpoints.
    - job_name: 'kubernetes-service-endpoints'
      kubernetes_sd_configs:
      - role: endpoints
      relabel_configs:
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_scheme]
        action: replace
        target_label: __scheme__
        regex: (https?)
      - source_labels: [__meta_kubernetes_service_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_service_annotation_prometheus_io_port]
        action: replace
        target_label: __address__
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
      - action: labelmap
        regex: __meta_kubernetes_service_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: kubernetes_namespace
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        target_label: kubernetes_name

    # Example scrape config for pods
    - job_name: 'kubernetes-pods'
      kubernetes_sd_configs:
      - role: pod

      relabel_configs:
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: true
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_path]
        action: replace
        target_label: __metrics_path__
        regex: (.+)
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        target_label: pod_name

    # scrape configs for Knative Serving
    # Autoscaler endpoint
    - job_name: autoscaler
      scrape_interval: 3s
      scrape_timeout: 3s
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      # Scrape only the the targets matching the following metadata
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_label_app, __meta_kubernetes_pod_container_port_name]
        action: keep
        regex: knative-serving;autoscaler;metrics
      # Rename metadata labels to be reader friendly
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        regex: (.*)
        target_label: namespace
        replacement: $1
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        regex: (.*)
        target_label: pod
        replacement: $1
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        regex: (.*)
        target_label: service
        replacement: $1

    # Activator pods
    - job_name: activator
      scrape_interval: 3s
      scrape_timeout: 3s
      kubernetes_sd_configs:
      - role: pod
      relabel_configs:
      # Scrape only the the targets matching the following metadata
      - source_labels: [__meta_kubernetes_namespace, __meta_kubernetes_pod_label_app, __meta_kubernetes_pod_container_port_name]
        action: keep
        regex: knative-serving;activator;metrics-port
      # Rename metadata labels to be reader friendly
      - source_labels: [__meta_kubernetes_namespace]
        action: replace
        regex: (.*)
        target_label: namespace
        replacement: $1
      - source_labels: [__meta_kubernetes_pod_name]
        action: replace
        regex: (.*)
        target_label: pod
        replacement: $1
      - source_labels: [__meta_kubernetes_service_name]
        action: replace
        regex: (.*)
        target_label: service
        replacement: $1
EOF

# Scale Prometheus down and back up so the new scrape 
oc scale -n istio-system --replicas=0 deployment/prometheus
oc scale -n istio-system --replicas=1 deployment/prometheus

# OLM
git clone https://github.com/operator-framework/operator-lifecycle-manager "$REPO_DIR/olm"
oc create -f "$REPO_DIR/olm/deploy/okd/manifests/latest/"
wait_for_all_pods openshift-operator-lifecycle-manager

# knative catalog source
oc apply -f "$DIR/../../knative-operators.catalogsource.yaml"

# for now, we must install the operators in specific namespaces, so...
oc create ns knative-build
oc create ns knative-serving
oc create ns knative-eventing

# install the operators for build, serving, and eventing
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: knative-build-subscription
  generateName: knative-build-
  namespace: knative-build
spec:
  source: knative-operators
  name: knative-build
  startingCSV: knative-build.${KNATIVE_BUILD_VERSION}
  channel: alpha
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: knative-serving-subscription
  generateName: knative-serving-
  namespace: knative-serving
spec:
  source: knative-operators
  name: knative-serving
  startingCSV: knative-serving.${KNATIVE_SERVING_VERSION}
  channel: alpha
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: knative-eventing-subscription
  generateName: knative-eventing-
  namespace: knative-eventing
spec:
  source: knative-operators
  name: knative-eventing
  startingCSV: knative-eventing.${KNATIVE_EVENTING_VERSION}
  channel: alpha
EOF

wait_for_all_pods knative-build
wait_for_all_pods knative-eventing
wait_for_all_pods knative-serving

# skip tag resolving for internal registry
oc -n knative-serving get cm config-controller -oyaml | sed "s/\(^ *registriesSkippingTagResolving.*$\)/\1,docker-registry.default.svc:5000/" | oc apply -f -

# Add Golang imagestreams to be able to build go based images
oc import-image -n openshift golang --from=centos/go-toolset-7-centos7 --confirm
oc import-image -n openshift golang:1.11 --from=centos/go-toolset-7-centos7 --confirm

# show all the pods
oc get pods --all-namespaces
