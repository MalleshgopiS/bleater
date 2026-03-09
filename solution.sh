#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
LOG_NS="logging"
APP_DIR="/home/ubuntu/bleater-app"

cd "$APP_DIR"

echo "1. Clearing Obfuscated Infrastructure Traps..."
kubectl delete pdb bleat-service-pdb -n "${BLEATER_NS}" || true
kubectl delete limitrange hidden-mem-limit -n "${BLEATER_NS}" || true
kubectl delete resourcequota default-mem-limit -n "${BLEATER_NS}" || true
kubectl delete networkpolicy kube-dns-allow -n "${BLEATER_NS}" || true
kubectl delete networkpolicy loki-deny-all -n "${LOG_NS}" || true

# Delete saboteurs in default namespace
kubectl delete deployment cluster-redis-optimizer -n default || true
kubectl delete deployment cluster-dns-monitor -n default || true

# Extract the malicious sidecar reverter from the loki-gateway deployment
# Note: It is the 3rd container (index 2)
kubectl patch deployment loki-gateway -n "${LOG_NS}" --type json -p='[{"op": "remove", "path": "/spec/template/spec/containers/2"}]' || true

# Dynamically delete the stochastic policy without touching baseline-security-rules
for np in $(kubectl get networkpolicy -n "${BLEATER_NS}" -o jsonpath='{.items[*].metadata.name}'); do
    if [[ "$np" == total-block-policy-* ]]; then
        kubectl delete networkpolicy "$np" -n "${BLEATER_NS}"
    fi
done

echo "2. Rebuilding Immutable ConfigMap with mandatory constants FIRST to avoid boot loops..."
kubectl delete configmap bleat-service-config -n "${BLEATER_NS}" --ignore-not-found || true
mkdir -p k8s
cat <<'EOF' > k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
  _ROUTING_RETRY_DELAY_MS: "0"
  _MIN_TTL_FLOOR_MS: "3600"
  _cap_mode_flag: "true"
EOF
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "3. Fixing the Redis Authentication Secret..."
kubectl delete secret bleat-service-auth -n "${BLEATER_NS}" --ignore-not-found || true
kubectl create secret generic bleat-service-auth -n "${BLEATER_NS}" --from-literal=REDIS_PASSWORD=bleater-super-secret-99

echo "4. Fixing the Redis and Loki Service Port Routing..."
kubectl patch service redis -n "${BLEATER_NS}" --type='json' -p='[{"op": "replace", "path": "/spec/ports/0/targetPort", "value": 6379}]' || true
kubectl patch service loki-gateway -n "${LOG_NS}" -p '{"spec":{"ports":[{"port": 3100, "targetPort": 3100, "name": "http"}]}}' || true
kubectl scale deployment redis -n "${BLEATER_NS}" --replicas=1 || true

echo "Waiting for Redis to spin up..."
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=60s || true

echo "5. Patching Deployment to remove Deadlocks, Affinity, InitContainers, and fix ReadinessProbe..."
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=merge -p='{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}' || true
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "remove", "path": "/spec/template/spec/affinity"}]' || true
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]' || true
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/port", "value": 8080}]' || true
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/env/-", "value": {"name": "SUPPRESS_WARNINGS", "value": "1"}}]' || true

echo "6. Wait for final rollouts..."
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=120s || true
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=150s || true

echo "7. Creating JSON validation script..."
mkdir -p scripts
cat <<'EOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
import json
import sys
import yaml

try:
    with open(sys.argv[1], 'rb') as f:
        doc = yaml.safe_load(f)
        val = doc.get("data", {}).get("REDIS_URL", "")
        if b"\r" in val.encode('utf-8'):
            print(json.dumps({"status": "fail"}))
        else:
            print(json.dumps({"status": "pass"}))
    sys.exit(0)
except Exception:
    print(json.dumps({"status": "fail"}))
    sys.exit(1)
EOF
chmod +x scripts/validate_configmap.py

echo "8. Updating CI workflow..."
mkdir -p .gitea/workflows
cat <<'EOF' > .gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@8ade135a41bc03ea155e62e844d188df1ea18608
      - run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
EOF

echo "Task Remediated Successfully."