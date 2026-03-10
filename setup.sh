#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Retry wrapper: handles transient etcd "database is locked" errors
kubectl_apply() {
    local attempt=1 max=8 delay=6
    while [ $attempt -le $max ]; do
        if kubectl apply -f - "$@"; then
            return 0
        fi
        echo "[kubectl_apply] attempt $attempt/$max failed, retrying in ${delay}s..."
        sleep $delay
        attempt=$((attempt + 1))
        delay=$((delay + 4))
    done
    echo "[kubectl_apply] ERROR: all $max attempts failed"
    return 1
}

echo "Ensuring supervisord is running..."
/usr/bin/supervisord -c /etc/supervisor/supervisord.conf 2>/dev/null || true
sleep 5

echo "Waiting for k3s to be ready..."
MAX_WAIT=180
ELAPSED=0
until kubectl get nodes >/dev/null 2>&1; do
    if [ "${ELAPSED}" -ge "${MAX_WAIT}" ]; then
        echo "Error: k3s is not ready after ${MAX_WAIT} seconds"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

# Wait for etcd to fully settle before issuing any writes
echo "Waiting for k3s API server to settle..."
sleep 10
until kubectl get serviceaccounts -n default >/dev/null 2>&1; do
    sleep 3
done
echo "k3s API server settled."

BLEATER_NS="bleater"
LOG_NS="logging"
UID_FILE="/tmp/bleat-service-deployment-uid"
PODS_FILE="/tmp/bleat-service-original-pods"

kubectl create namespace "${BLEATER_NS}" --dry-run=client -o yaml | kubectl_apply
kubectl create namespace "${LOG_NS}" --dry-run=client -o yaml | kubectl_apply

# --- HIDDEN CORRUPTION CRONJOB (Tier 3 Difficulty Tuning) ---
cat <<'EOF' | kubectl_apply
apiVersion: v1
kind: ServiceAccount
metadata:
  name: legacy-sync-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: legacy-sync-sa-admin
subjects:
- kind: ServiceAccount
  name: legacy-sync-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: hidden-sync-script
  namespace: default
data:
  sync.py: |
    import urllib.request, json, ssl
    try:
        token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
        ctx = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
        req = urllib.request.Request(
            'https://kubernetes.default.svc/api/v1/namespaces/bleater/configmaps/bleat-service-config',
            data=json.dumps({"data": {"REDIS_URL": "redis://redis.bleater.svc.cluster.local:6379/0\r"}}).encode(),
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/strategic-merge-patch+json'},
            method='PATCH'
        )
        urllib.request.urlopen(req, context=ctx)
    except Exception as e:
        pass
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: legacy-config-sync
  namespace: default
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: legacy-sync-sa
          containers:
          - name: sync
            image: python:3.11-slim
            command: ["python", "/app/sync.py"]
            volumeMounts:
            - name: script
              mountPath: /app
          volumes:
          - name: script
            configMap:
              name: hidden-sync-script
          restartPolicy: OnFailure
EOF

# --- SECONDARY HIDDEN CORRUPTION CRONJOB (monitoring namespace) ---
cat <<'EOF' | kubectl_apply
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: platform-config-sa
  namespace: monitoring
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: platform-config-sa-admin
subjects:
- kind: ServiceAccount
  name: platform-config-sa
  namespace: monitoring
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: platform-sync-script
  namespace: monitoring
data:
  sync.py: |
    import urllib.request, json, ssl
    try:
        token = open('/var/run/secrets/kubernetes.io/serviceaccount/token').read()
        ctx = ssl.create_default_context(cafile='/var/run/secrets/kubernetes.io/serviceaccount/ca.crt')
        req = urllib.request.Request(
            'https://kubernetes.default.svc/api/v1/namespaces/bleater/configmaps/bleat-service-config',
            data=json.dumps({"data": {"REDIS_URL": "redis://redis.bleater.svc.cluster.local:6379/0\r"}}).encode(),
            headers={'Authorization': f'Bearer {token}', 'Content-Type': 'application/strategic-merge-patch+json'},
            method='PATCH'
        )
        urllib.request.urlopen(req, context=ctx)
    except Exception as e:
        pass
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: platform-config-sync
  namespace: monitoring
spec:
  schedule: "* * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: platform-config-sa
          containers:
          - name: sync
            image: python:3.11-slim
            command: ["python", "/app/sync.py"]
            volumeMounts:
            - name: script
              mountPath: /app
          volumes:
          - name: script
            configMap:
              name: platform-sync-script
          restartPolicy: OnFailure
EOF

# RBAC: give the agent access to the monitoring namespace so it CAN delete the CronJob once found
cat <<'EOF' | kubectl_apply
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ubuntu-user-monitoring-admin
  namespace: monitoring
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-user-monitoring-admin-binding
  namespace: monitoring
subjects:
- kind: ServiceAccount
  name: ubuntu-user
  namespace: default
roleRef:
  kind: Role
  name: ubuntu-user-monitoring-admin
  apiGroup: rbac.authorization.k8s.io
EOF


sleep 5
# --- REDIS MOCK DEPLOYMENT ---
cat <<'EOF' | kubectl_apply
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-script
  namespace: bleater
data:
  redis_server.py: |
    import socketserver
    class Handler(socketserver.StreamRequestHandler):
        def handle(self):
            try:
                while True:
                    line = self.rfile.readline()
                    if not line: return
                    if b"PING" in line.upper():
                        self.wfile.write(b"+PONG\r\n")
                        self.wfile.flush()
                        return
            except Exception: return
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
    Server(("", 6379), Handler).serve_forever()
EOF

cat <<'EOF' | kubectl_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: bleater
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: python:3.11-slim
        command: ["python", "/app/redis_server.py"]
        ports:
        - containerPort: 6379
        volumeMounts:
        - name: redis-script
          mountPath: /app
      volumes:
      - name: redis-script
        configMap:
          name: redis-script
          defaultMode: 0555
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: bleater
spec:
  selector:
    app: redis
  ports:
  - name: redis
    port: 6379
    targetPort: 6380  # <--- SABOTAGE 1: Wrong target port!
EOF

sleep 5
# --- LOKI MOCK ---
cat <<'EOF' | kubectl_apply
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-script
  namespace: logging
data:
  server.py: |
    import json, os, re, urllib.parse
    from http.server import BaseHTTPRequestHandler, HTTPServer
    STORE = "/data/logs.jsonl"
    os.makedirs("/data", exist_ok=True)
    open(STORE, "a", encoding="utf-8").close()

    def load_entries():
        entries = []
        with open(STORE, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line: continue
                try: entries.append(json.loads(line))
                except json.JSONDecodeError: continue
        return entries

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): return
        def _send(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def do_POST(self):
            if self.path != "/loki/api/v1/push":
                self._send(404, {"status": "error"})
                return
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            with open(STORE, "a", encoding="utf-8") as handle:
                for stream in payload.get("streams", []):
                    labels = stream.get("stream", {})
                    for ts, message in stream.get("values", []):
                        handle.write(json.dumps({"ts": str(ts), "labels": labels, "message": message}) + "\n")
            self._send(204, {})
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/ready":
                self._send(200, {"status": "ready"})
                return
            if parsed.path != "/loki/api/v1/query":
                self._send(404, {"status": "error"})
                return
            self._send(200, {"status": "success", "data": {"resultType": "streams", "result": []}})
    HTTPServer(("", 3100), Handler).serve_forever()
EOF

cat <<'EOF' | kubectl_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki-gateway
  namespace: logging
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki-gateway
  template:
    metadata:
      labels:
        app: loki-gateway
    spec:
      containers:
      - name: loki-gateway
        image: python:3.11-slim
        command: ["python", "/app/server.py"]
        ports:
        - containerPort: 3100
        readinessProbe:
          httpGet:
            path: /ready
            port: 3100
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - name: app
          mountPath: /app
        - name: data
          mountPath: /data
      volumes:
      - name: app
        configMap:
          name: loki-script
          defaultMode: 0555
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: loki-gateway
  namespace: logging
spec:
  selector:
    app: loki-gateway
  ports:
  - name: http
    port: 3100
    targetPort: 3101 # <--- SABOTAGE 2: Wrong target port for Loki
EOF

sleep 5
# --- BLEAT APP MOCK ---
cat <<'EOF' | kubectl_apply
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-script
  namespace: bleater
data:
  app.py: |
    import json, os, socket, sys, time, urllib.parse, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    REDIS_URL = os.environ.get("REDIS_URL", "")
    LOKI_URL = os.environ.get("LOKI_URL", "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME = os.environ.get("HOSTNAME", "bleat-service")

    def push_log(level, message):
        payload = {"streams": [{"stream": {"app": "bleat-service", "level": level, "pod": POD_NAME}, "values": [[str(int(time.time() * 1000000000)), message]]}]}
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(LOKI_URL.rstrip("/") + "/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"})
        try: urllib.request.urlopen(request, timeout=2)
        except Exception: pass
        print(message, flush=True)

    def fail(message):
        push_log("error", message)
        sys.exit(1)

    if "\r" in REDIS_URL or "\n" in REDIS_URL:
        fail(f"invalid address: REDIS_URL contains control characters: {REDIS_URL!r}")

    parsed = urllib.parse.urlparse(REDIS_URL)
    if parsed.scheme != "redis" or not parsed.hostname or not parsed.port:
        fail(f"invalid address: malformed REDIS_URL={REDIS_URL!r}")

    try:
        with socket.create_connection((parsed.hostname, parsed.port), timeout=5) as sock:
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            response = sock.recv(64)
    except OSError as exc:
        fail(f"connection refused: {exc}")

    if b"PONG" not in response:
        fail(f"invalid redis response: {response!r}")

    push_log("info", f"redis connection established to {parsed.hostname}:{parsed.port}")
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): return
        def do_GET(self):
            if self.path == "/ready":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
            else:
                self.send_response(200)
                self.end_headers()
    HTTPServer(("", 8080), Handler).serve_forever()
EOF

sleep 5
# --- LOCAL REPO INITIALIZATION ---
mkdir -p /home/ubuntu/bleater-app/k8s /home/ubuntu/bleater-app/.gitea/workflows /home/ubuntu/bleater-app/issues
cd /home/ubuntu/bleater-app

cat <<'EOF' > k8s/bleat-service-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
EOF

cat <<'EOF' > .gitea/workflows/bleat-ci.yaml
name: bleat-ci
on: [push, pull_request]
jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo "tests passed"
EOF

cat << 'EOF' > issues/issue-1-prod-down.md
Prod down: bleat-service CrashLooping — connection refused

bleat-service has been CrashLooping since around 14:00 UTC. Pods are failing
to start and we are seeing no traffic.

What we know so far:
- The service is not connecting to Redis at all (connection refused / timeout).
- Centralized logging (Loki) is not receiving logs from bleat-service either,
  so we cannot see detailed error output there.
- Someone mentioned they fixed the ConfigMap encoding issue last week, but
  the CRLF corruption appears to have come back. It feels like something is
  actively reverting our fixes — worth auditing what's running in the cluster.

Next steps would be to inspect the service routing, check for any automation
that might be touching our config, and make sure the fix actually sticks.
EOF

cat << 'EOF' > issues/issue-2-ci-flaky.md
Need CI checks for bad line endings

Someone pushed a config map with weird invisible characters (\r / carriage returns) that broke the connection string parsing. We need a pipeline validation script at `scripts/validate_configmap.py` to check for carriage returns in our k8s manifests, and run it in our CI workflow to stop this from happening.
EOF

# Give the ubuntu user permission to edit these files
chown -R ubuntu:ubuntu /home/ubuntu/bleater-app || chown -R 1000:1000 /home/ubuntu/bleater-app || true

kubectl apply -f k8s/bleat-service-configmap.yaml --retry=3

cat <<'EOF' | kubectl_apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bleat-service
  namespace: bleater
spec:
  replicas: 2
  selector:
    matchLabels:
      app: bleat-service
  template:
    metadata:
      labels:
        app: bleat-service
    spec:
      containers:
      - name: bleat-service
        image: python:3.11-slim
        command: ["python", "/app/app.py"]
        env:
        - name: REDIS_URL
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: REDIS_URL
        - name: LOKI_URL
          value: http://loki-gateway.logging.svc.cluster.local:3100
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - name: app
          mountPath: /app
      volumes:
      - name: app
        configMap:
          name: bleat-service-script
          defaultMode: 0555
EOF

echo "Waiting for redis and loki deployments..."
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=180s || true
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=180s || true

echo "Waiting for bleat-service pods to appear in broken state..."
sleep 10
kubectl get deployment bleat-service -n "${BLEATER_NS}" -o jsonpath='{.metadata.uid}' > "${UID_FILE}"

# Use Python JSON parser to ensure we only get valid bleat-service pods and ignore terminating ones
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for p in data.get("items", []):
    if not p["metadata"].get("deletionTimestamp") and p["metadata"]["name"].startswith("bleat-service-"):
        print(p["metadata"]["name"])
' | sort > "${PODS_FILE}"

chmod 400 "${UID_FILE}" "${PODS_FILE}"

echo "Setup complete."