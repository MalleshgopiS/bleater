#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"

echo "1. Diagnose hidden characters..."
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" \
  -o jsonpath='{.data.REDIS_URL}' | cat -v || true
echo

echo "2. Write clean ConfigMap manifest..."
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

echo "3. Create strict validation script..."
mkdir -p scripts
cat <<'EOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
import pathlib, re, sys

CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
ESC = re.compile(r"(\\r|\\x0d|\\u000d)", re.I)

def bad(text):
    if "\r" in text:
        return True
    if CONTROL.search(text):
        return True
    if ESC.search(text):
        return True
    return False

rc = 0
for f in sys.argv[1:]:
    p = pathlib.Path(f)
    if not p.exists():
        rc = 1
        continue
    t = p.read_text()
    if bad(t):
        rc = 1

sys.exit(rc)
EOF
chmod +x scripts/validate_configmap.py

echo "4. Update CI workflow..."
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

echo "5. Validate manifest..."
python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml

echo "6. Apply fixed ConfigMap..."
kubectl apply -f k8s/bleat-service-configmap.yaml

echo "7. Rolling restart (UID preserved)..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"

echo "8. Wait for rollout..."
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=300s

echo "9. Wait for pods Ready..."
kubectl wait --for=condition=ready pod -l app=bleat-service \
  -n "${BLEATER_NS}" --timeout=180s

echo "10. Verify Running pods..."
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service
echo

echo "11. Pick Running pod..."
POD="$(kubectl get pods -n ${BLEATER_NS} -l app=bleat-service \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')"

if [ -z "${POD}" ]; then
  echo "No Running bleat-service pod found"
  exit 1
fi

echo "12. Verify REDIS_URL env..."
kubectl exec -n "${BLEATER_NS}" "$POD" -- printenv REDIS_URL
echo

echo "13. Check app logs..."
kubectl logs -n "${BLEATER_NS}" "$POD" --tail=50 | grep -i redis || true
echo

echo "Remediation complete."