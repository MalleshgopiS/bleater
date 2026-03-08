#!/usr/bin/env bash
set -euo pipefail

BLEATER_NS="bleater"
APP_ROOT="/home/ubuntu/bleater-app"

echo "1. Fix services..."

# Fix Redis service port mapping
kubectl patch service redis -n "${BLEATER_NS}" \
  --type merge \
  -p '{"spec":{"ports":[{"port":6379,"targetPort":6379}]}}' || true

# Fix Loki gateway service port mapping
kubectl patch service loki-gateway -n "${BLEATER_NS}" \
  --type merge \
  -p '{"spec":{"ports":[{"port":3100,"targetPort":3100}]}}' || true


echo "2. Stop hidden config corrupter..."

# Remove hidden cronjob that re-corrupts ConfigMap
kubectl delete cronjob legacy-config-sync -n "${BLEATER_NS}" --ignore-not-found || true
kubectl delete configmap hidden-sync-script -n "${BLEATER_NS}" --ignore-not-found || true


echo "3. Clean repo ConfigMap manifest..."

MANIFEST="${APP_ROOT}/k8s/bleat-service-configmap.yaml"

if [ -f "${MANIFEST}" ]; then
  # Remove CRLF and carriage returns
  sed -i 's/\r$//' "${MANIFEST}"
  sed -i 's/\\r//g' "${MANIFEST}"
fi


echo "4. Validation script..."

mkdir -p "${APP_ROOT}/scripts"

cat > "${APP_ROOT}/scripts/validate_configmap.py" << 'PY'
#!/usr/bin/env python3
import sys, re, pathlib

CONTROL = re.compile(r"[\x00-\x1f\x7f]")
ESC = re.compile(r"(\\r|\\x0d|\\u000d)", re.I)

def bad(text):
    return "\r" in text or CONTROL.search(text) or ESC.search(text)

ok = True
for path in sys.argv[1:]:
    p = pathlib.Path(path)
    if not p.exists():
        print(f"Missing file: {p}", file=sys.stderr)
        ok = False
        continue
    t = p.read_text(errors="ignore")
    if bad(t):
        print(f"Invalid control characters in {p}", file=sys.stderr)
        ok = False

sys.exit(1 if not ok else 0)
PY

chmod +x "${APP_ROOT}/scripts/validate_configmap.py"


echo "5. CI workflow..."

mkdir -p "${APP_ROOT}/.gitea/workflows"

cat > "${APP_ROOT}/.gitea/workflows/bleat-ci.yaml" << 'YAML'
name: Bleat Config Validation
on: [push]

jobs:
  validate-config:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate ConfigMap
        run: |
          python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
YAML


echo "6. Replace live ConfigMap (CRLF fix)..."

kubectl delete configmap bleat-service-config -n "${BLEATER_NS}" --ignore-not-found

kubectl create configmap bleat-service-config \
  --from-literal=REDIS_URL=redis://redis.bleater.svc.cluster.local:6379/0 \
  -n "${BLEATER_NS}"


echo "7. Force rolling restart (UID preserved)..."

# Delete pods instead of rollout status (more reliable in cloud)
kubectl delete pod -n "${BLEATER_NS}" -l app=bleat-service --wait=false || true


echo "8. Stabilization wait..."

sleep 45


echo "Done."