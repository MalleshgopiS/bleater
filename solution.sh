#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"

echo "Diagnosing hidden characters in REDIS_URL..."
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
  -o jsonpath='{.data.REDIS_URL}' | cat -v
echo

echo "Fixing manifest CLEANLY..."
mkdir -p k8s scripts .gitea/workflows
MANIFEST="k8s/bleat-service-configmap.yaml"

# 1. Normalize line endings
sed -i 's/\r$//' "$MANIFEST"

# 2. Remove ALL binary control characters
perl -i -pe 's/[\x00-\x1F\x7F]//g' "$MANIFEST"

# 3. Remove escaped CR encodings
sed -i 's/\\r//g' "$MANIFEST"
sed -i 's/\\x0d//gi' "$MANIFEST"
sed -i 's/\\u000d//gi' "$MANIFEST"

# 4. Force exact value
sed -i 's|REDIS_URL:.*|REDIS_URL: redis://redis.bleater.svc.cluster.local:6379/0|' "$MANIFEST"

echo "Creating validation script..."
cat > scripts/validate_configmap.py <<'PYEOF'
#!/usr/bin/env python3
import sys, pathlib, re
CONTROL = re.compile(r"[\x00-\x1F\x7F]")
ESC = re.compile(r"(\\r|\\x0d|\\u000d)", re.I)
def bad(t):
    return "\r" in t or CONTROL.search(t) or ESC.search(t)
rc = 0
for f in sys.argv[1:]:
    p = pathlib.Path(f)
    if not p.exists() or bad(p.read_text()):
        rc = 1
sys.exit(rc)
PYEOF
chmod +x scripts/validate_configmap.py

echo "Creating CI workflow..."
cat > .gitea/workflows/bleat-ci.yaml <<'YAMLEOF'
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
YAMLEOF

echo "Validating manifest..."
python3 scripts/validate_configmap.py "$MANIFEST"

echo "Applying fixed ConfigMap..."
kubectl apply -f "$MANIFEST"

echo "Rolling restart..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=240s

echo "Ensuring old pods gone..."
kubectl get pods -n "${BLEATER_NS}" -o name | \
  grep bleater-bleat-service | \
  xargs -r kubectl delete -n "${BLEATER_NS}" --wait=true || true

sleep 5

echo "Verifying pod env..."
POD=$(kubectl get pods -n ${BLEATER_NS} -l app=bleat-service \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n "${BLEATER_NS}" "$POD" -- printenv REDIS_URL

echo "Checking Redis logs..."
kubectl logs -n "${BLEATER_NS}" "$POD" | grep -i "redis connection established"

echo "Done."