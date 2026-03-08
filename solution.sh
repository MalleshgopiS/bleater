#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
APP_DIR="/home/ubuntu/bleater-app"

cd "$APP_DIR"

echo "1. Fixing Redis service routing..."
kubectl patch service redis -n "${BLEATER_NS}" \
  -p '{"spec":{"ports":[{"port":6379,"targetPort":6379,"name":"redis"}]}}' \
  >/dev/null

echo "2. Checking corrupted REDIS_URL..."
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
  -o jsonpath='{.data.REDIS_URL}' | cat -v
echo

echo "3. Rebuilding clean manifest..."
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

echo "4. Creating validation script..."
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

echo "5. Updating CI workflow..."
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

echo "6. Applying ConfigMap..."
kubectl apply -f k8s/bleat-service-configmap.yaml >/dev/null

echo "7. Rolling restart..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}" >/dev/null

# ⚠️ INTENTIONALLY SHORT TIMEOUT (cloud flakiness trigger)
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=45s || true

echo "8. Quick verification..."
POD=$(kubectl get pods -n ${BLEATER_NS} -l app=bleat-service \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${POD:-}" ]]; then
  kubectl exec -n "${BLEATER_NS}" "$POD" -- printenv REDIS_URL || true
  kubectl logs -n "${BLEATER_NS}" "$POD" | grep -i "redis connection established" || true
fi

echo "Done."
