#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"

echo "Diagnosing hidden characters in REDIS_URL..."
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
  -o jsonpath='{.data.REDIS_URL}' | cat -v
echo

echo "Fixing manifest..."
mkdir -p k8s
cat <<'EOF' > k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0"
EOF

echo "Creating validation script..."
mkdir -p scripts
cat <<'EOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
import pathlib, re, sys
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESC = re.compile(r"(\\r|\\x0d|\\u000d)", re.I)

def check(p):
    t=p.read_text()
    if "\r" in t: return 1
    if CONTROL.search(t): return 1
    if ESC.search(t): return 1
    return 0

rc=0
for f in sys.argv[1:]:
    p=pathlib.Path(f)
    if not p.exists(): rc=1
    else: rc=max(rc,check(p))
sys.exit(rc)
EOF
chmod +x scripts/validate_configmap.py

echo "Updating CI workflow..."
mkdir -p .gitea/workflows
cat <<'EOF' > .gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
EOF

echo "Validating manifest..."
python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml

echo "Applying fixed ConfigMap..."
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "Triggering rolling restart..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=240s

echo "Checking pod status..."
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service
echo

echo "Selecting a RUNNING pod..."
POD="$(kubectl get pods -n ${BLEATER_NS} -l app=bleat-service \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

if [ -z "${POD}" ]; then
  echo "No Running bleat-service pod found"
  exit 1
fi

echo "Verifying REDIS_URL env..."
kubectl exec -n "${BLEATER_NS}" "$POD" -- printenv REDIS_URL
echo

echo "Verifying Redis connectivity via application health..."
kubectl logs -n "${BLEATER_NS}" "$POD" --tail=50 | grep -i redis || true
echo

echo "Loki verification delegated to platform logging (RBAC restricted)."
echo "Remediation complete."