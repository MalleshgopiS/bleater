#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"

echo "Diagnosing hidden characters in REDIS_URL..."
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
  -o jsonpath='{.data.REDIS_URL}' | cat -v
echo

echo "Fixing manifest in-place (no recreation)..."
mkdir -p k8s

# Write clean manifest (NO quotes, NO CRLF)
cat > k8s/bleat-service-configmap.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: redis://redis.bleater.svc.cluster.local:6379/0
EOF

# Ensure no CRLF
sed -i 's/\r$//' k8s/bleat-service-configmap.yaml

echo "Creating strict validation script..."
mkdir -p scripts

cat > scripts/validate_configmap.py <<'EOF'
#!/usr/bin/env python3
import pathlib, re, sys

CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESC = re.compile(r"(\\r|\\x0d|\\u000d)", re.I)

def check(p):
    t = p.read_text()
    if "\r" in t:
        return 1
    if CONTROL.search(t):
        return 1
    if ESC.search(t):
        return 1
    return 0

rc = 0
for f in sys.argv[1:]:
    p = pathlib.Path(f)
    if not p.exists():
        rc = 1
    else:
        rc = max(rc, check(p))

sys.exit(rc)
EOF

chmod +x scripts/validate_configmap.py

echo "Updating CI workflow..."
mkdir -p .gitea/workflows

cat > .gitea/workflows/bleat-ci.yaml <<'EOF'
name: bleat-ci
on: [push, pull_request]

jobs:
  validate-configmap:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate ConfigMap
        run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
EOF

echo "Validating manifest..."
python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml

echo "Applying fixed ConfigMap..."
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "Triggering guaranteed rolling restart..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=240s

echo "Cleaning up legacy pods to ensure rollout detection..."
kubectl get pods -n "${BLEATER_NS}" -o name | \
  grep bleater-bleat-service || true | \
  xargs -r kubectl delete -n "${BLEATER_NS}" --wait=false || true

sleep 5

echo "Checking pod status..."
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service
echo

echo "Selecting a RUNNING pod..."
POD="$(kubectl get pods -n ${BLEATER_NS} -l app=bleat-service \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

echo "Verifying REDIS_URL env..."
kubectl exec -n "${BLEATER_NS}" "${POD}" -- printenv REDIS_URL

echo "Verifying Redis connectivity via logs..."
kubectl logs -n "${BLEATER_NS}" "${POD}" | grep -i "redis connection established"

echo
echo "Remediation complete."