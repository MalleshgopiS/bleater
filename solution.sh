#!/usr/bin/env bash
set -euo pipefail

BLEATER_NS="bleater"
APP_ROOT="/home/ubuntu/bleater-app"

echo "1. Fix services..."

kubectl patch service redis -n "${BLEATER_NS}" \
  --type merge \
  -p '{"spec":{"ports":[{"port":6379,"targetPort":6379}]}}' || true

kubectl patch service loki-gateway -n "${BLEATER_NS}" \
  --type merge \
  -p '{"spec":{"ports":[{"port":3100,"targetPort":3100}]}}' || true


echo "2. Stop hidden config corrupter..."

kubectl delete cronjob legacy-config-sync -n "${BLEATER_NS}" --ignore-not-found || true
kubectl delete configmap hidden-sync-script -n "${BLEATER_NS}" --ignore-not-found || true


echo "3. Clean repo ConfigMap manifest..."

MANIFEST="${APP_ROOT}/k8s/bleat-service-configmap.yaml"

# Remove CRLF + escaped CR
sed -i 's/\r$//' "${MANIFEST}"
sed -i 's/\\r//g' "${MANIFEST}"


echo "4. Validation script..."

mkdir -p "${APP_ROOT}/scripts"

cat > "${APP_ROOT}/scripts/validate_configmap.py" << 'PY'
#!/usr/bin/env python3
import sys, pathlib

def bad(text):
    if "\r" in text:
        return True
    for c in text:
        if ord(c) < 32 and c not in ("\n", "\t"):
            return True
    if "\\r" in text or "\\x0d" in text or "\\u000d" in text:
        return True
    return False

ok = True
for p in sys.argv[1:]:
    path = pathlib.Path(p)
    if not path.exists():
        ok = False
        continue
    t = path.read_text(errors="ignore")
    if bad(t):
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


echo "6. Replace live ConfigMap (clean apply)..."

kubectl delete configmap bleat-service-config -n "${BLEATER_NS}" --ignore-not-found

kubectl apply -f "${MANIFEST}"


echo "7. Proper rolling restart..."

kubectl rollout restart deployment bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment bleat-service -n "${BLEATER_NS}" --timeout=180s


echo "8. Wait for app to stabilize..."

sleep 60

echo "Done."