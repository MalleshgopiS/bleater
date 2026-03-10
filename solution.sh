#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
BLEATER_NS="bleater"
LOG_NS="logging"
APP_DIR="/home/ubuntu/bleater-app"

cd "$APP_DIR" || exit 1

echo "1. Clearing Obfuscated Infrastructure Traps..."
kubectl delete pdb bleat-service-pdb -n "${BLEATER_NS}" || true
kubectl delete limitrange hidden-mem-limit -n "${BLEATER_NS}" || true
kubectl delete resourcequota default-mem-limit -n "${BLEATER_NS}" || true
kubectl delete networkpolicy redis-security-policy -n "${BLEATER_NS}" || true
kubectl delete networkpolicy loki-deny-all -n "${LOG_NS}" || true

for np in $(kubectl get networkpolicy -n "${BLEATER_NS}" -o name | grep "total-block-policy-" || true); do
    kubectl delete "$np" -n "${BLEATER_NS}" || true
done

kubectl delete cronjob legacy-config-sync -n default || true
kubectl delete deployment redis-autoscaler -n default || true
kubectl delete daemonset rancher-servicelb-agent -n default || true

kubectl patch deployment loki-gateway -n "${LOG_NS}" --type json -p='[{"op": "remove", "path": "/spec/template/spec/containers/2"}]' || true
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=120s || true

echo "2. Patching Deployment to remove Affinity, InitContainers, and fix Probes..."
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "remove", "path": "/spec/template/spec/affinity"}]' || true
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "remove", "path": "/spec/template/spec/initContainers"}]' || true
kubectl patch deployment bleat-service -n "${BLEATER_NS}" --type=json -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/readinessProbe/httpGet/port", "value": 8080}]' || true

echo "3. Fixing Service Ports..."
kubectl patch service redis -n "${BLEATER_NS}" -p '{"spec":{"ports":[{"port": 6379, "targetPort": 6379, "name": "redis"}]}}' || true
kubectl patch service loki-gateway -n "${LOG_NS}" -p '{"spec":{"ports":[{"port": 3100, "targetPort": 3100, "name": "http"}]}}' || true

echo "4. Fixing the Authentication Secret..."
kubectl delete secret bleat-service-auth -n "${BLEATER_NS}" --ignore-not-found
kubectl create secret generic bleat-service-auth -n "${BLEATER_NS}" --from-literal=REDIS_PASSWORD=bleater-super-secret-99

echo "5. Rebuilding ConfigMap..."
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

echo "6. Scaling Redis and waiting for Ready state..."
kubectl scale deployment redis -n "${BLEATER_NS}" --replicas=1 || true
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=120s || true

echo "7. Creating JSON validation script..."
mkdir -p scripts
cat <<'EOF' > scripts/validate_configmap.py
#!/usr/bin/env python3
import pathlib, sys, json

def check(p):
    try:
        t = p.read_bytes()
        if b"\r" in t: return 1
        return 0
    except:
        return 1

rc=0
for f in sys.argv[1:]:
    p=pathlib.Path(f)
    if not p.exists(): rc=1
    else: rc=max(rc,check(p))

if rc == 0:
    print(json.dumps({"status": "pass"}))
    sys.exit(0)
else:
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
      - uses: actions/checkout@v4
      - run: python3 scripts/validate_configmap.py k8s/bleat-service-configmap.yaml
EOF

echo "9. Graceful Rollout..."
kubectl rollout restart deployment/bleat-service -n "${BLEATER_NS}"
kubectl rollout status deployment/bleat-service -n "${BLEATER_NS}" --timeout=240s

echo "Task Remediated Successfully."