#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
APP_DIR="/home/ubuntu/bleater-app"
cd "$APP_DIR"

echo "1. Fix services..."
kubectl patch service redis -n "${BLEATER_NS}" \
  -p '{"spec":{"ports":[{"port":6379,"targetPort":6379,"name":"redis"}]}}' >/dev/null

kubectl patch service loki-gateway -n logging \
  -p '{"spec":{"ports":[{"port":3100,"targetPort":3100,"name":"http"}]}}' >/dev/null

echo "2. Clean repo ConfigMap manifest..."
mkdir -p k8s
cat > k8s/bleat-service-configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: redis://redis.bleater.svc.cluster.local:6379/0
EOF

echo "3. Validation script..."
mkdir -p scripts
cat > scripts/validate_configmap.py <<'PYEOF'
#!/usr/bin/env python3
import pathlib,re,sys
CONTROL=re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESC=re.compile(r"(\\r|\\x0d|\\u000d)",re.I)
def bad(t): return "\r" in t or CONTROL.search(t) or ESC.search(t)
rc=0
for f in sys.argv[1:]:
 p=pathlib.Path(f)
 if not p.exists() or bad(p.read_text()): rc=1
sys.exit(rc)
PYEOF
chmod +x scripts/validate_configmap.py

echo "4. CI workflow..."
mkdir -p .gitea/workflows
cat > .gitea/workflows/bleat-ci.yaml <<'YAML'
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
YAML

echo "5. Replace live ConfigMap (CRLF fix)..."
kubectl delete configmap bleat-service-config -n "${BLEATER_NS}" --ignore-not-found
kubectl create configmap bleat-service-config \
  --from-literal=REDIS_URL=redis://redis.bleater.svc.cluster.local:6379/0 \
  -n "${BLEATER_NS}"

echo "6. Rolling restart..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}" >/dev/null

# Slightly short wait → cloud flakiness
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=90s || true

echo "7. Quick stabilization..."
sleep 8

echo "Done."