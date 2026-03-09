#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
APP_DIR="/home/ubuntu/bleater-app"

cd "$APP_DIR"

echo "1. Clearing Obfuscated Infrastructure Traps..."
kubectl delete cronjob metrics-collector-job -n "${BLEATER_NS}" || true
kubectl delete resourcequota default-mem-limit -n "${BLEATER_NS}" || true
kubectl delete networkpolicy kube-dns-allow -n "${BLEATER_NS}" || true
kubectl delete networkpolicy total-block-policy -n "${BLEATER_NS}" || true

echo "2. Fixing the Redis and Loki Service Port Routing..."
kubectl patch service redis -n "${BLEATER_NS}" -p '{"spec":{"ports":[{"port": 6379, "targetPort": 6379, "name": "redis"}]}}'
kubectl patch service loki-gateway -n "logging" -p '{"spec":{"ports":[{"port": 3100, "targetPort": 3100, "name": "http"}]}}'

echo "3. Fixing the Redis Authentication Secret via stateless apply..."
kubectl create secret generic bleat-service-auth -n "${BLEATER_NS}" --from-literal=REDIS_PASSWORD=bleater-super-secret-99 --dry-run=client -o yaml | kubectl apply -f -

echo "4. Rebuilding ConfigMap with mandatory constants..."
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

echo "5. Creating JSON validation script..."
mkdir -p scripts
cat <<'EOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
import json, pathlib, sys

def check(p):
    # Use read_bytes() to prevent Python from auto-converting \r to \n
    t = p.read_bytes()
    return b"\r" in t

rc=0
for f in sys.argv[1:]:
    p=pathlib.Path(f)
    if not p.exists() or check(p): rc=1

if rc == 0:
    print(json.dumps({"status": "pass"}))
else:
    print(json.dumps({"status": "fail"}))
sys.exit(rc)
EOF
chmod +x scripts/validate_configmap.py

echo "6. Updating CI workflow..."
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

echo "7. Graceful Rollout (No force flags)..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=300s

echo "Task Remediated Successfully."