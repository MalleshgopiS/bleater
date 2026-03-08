#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

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

BLEATER_NS="bleater"
LOG_NS="logging"
UID_FILE="/tmp/bleat-service-deployment-uid"
PODS_FILE="/tmp/bleat-service-original-pods"

kubectl create namespace "${BLEATER_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${LOG_NS}" --dry-run=client -o yaml | kubectl apply -f -

# --- FIX: GRANT UBUNTU USER RBAC FOR LOGGING NAMESPACE ---
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: logging
  name: ubuntu-user-logging-admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ubuntu-user-logging-admin-binding
  namespace: logging
subjects:
- kind: ServiceAccount
  name: ubuntu-user
  namespace: default
roleRef:
  kind: Role
  name: ubuntu-user-logging-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# 🚨 THE QUOTA TRAP: This silently prevents rolling restarts!
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ResourceQuota
metadata:
  name: bleater-strict-quota
  namespace: bleater
spec:
  hard:
    pods: "2"
EOF

# --- REDIS MOCK DEPLOYMENT (Robust TCP parsing & Auth) ---
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-script
  namespace: bleater
data:
  redis_server.py: |
    import socketserver, sys
    expected_pass = sys.argv[1] if len(sys.argv) > 1 else None
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            try:
                authenticated = False if expected_pass else True
                while True:
                    data = self.request.recv(1024)
                    if not data: return
                    data_str = data.upper().decode('utf-8', errors='ignore')
                    if "AUTH" in data_str:
                        if expected_pass and expected_pass in data.decode('utf-8', errors='ignore'):
                            authenticated = True
                            self.request.sendall(b"+OK\r\n")
                        else:
                            self.request.sendall(b"-ERR invalid password\r\n")
                        continue
                    if "PING" in data_str:
                        if not authenticated:
                            self.request.sendall(b"-NOAUTH Authentication required.\r\n")
                        else:
                            self.request.sendall(b"+PONG\r\n")
                        return
            except Exception: return
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
    Server(("", 6379), Handler).serve_forever()
---
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
        command: ["python", "/app/redis_server.py", "bleater-super-secret-99"]
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

# --- NETWORK POLICY TRAP ---
cat <<'EOF' | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: redis-security-policy
  namespace: bleater
spec:
  podSelector:
    matchLabels:
      app: redis
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          access: redis
    ports:
    - protocol: TCP
      port: 6379
EOF

# --- LOKI MOCK ---
cat <<'EOF' | kubectl apply -f -
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
---
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

# --- BLEAT APP MOCK ---
cat <<'EOF' | kubectl apply -f -
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
    REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
    LOKI_URL = os.environ.get("LOKI_URL", "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME = os.environ.get("HOSTNAME", "bleat-service")

    # 🚨 HIDDEN IMPLEMENTATION DETAIL ENFORCEMENT
    # If the agent wipes these variables from the ConfigMap, the app crashes!
    if os.environ.get("_cap_mode_flag") != "true" or not os.environ.get("_MIN_TTL_FLOOR_MS"):
        print("FATAL: Missing internal cap_mode or TTL floor configurations. Halting.", flush=True)
        sys.exit(1)

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
            if REDIS_PASSWORD:
                sock.sendall(f"*2\r\n$4\r\nAUTH\r\n${len(REDIS_PASSWORD)}\r\n{REDIS_PASSWORD}\r\n".encode())
                resp = sock.recv(1024)
                if b"-ERR" in resp: fail(f"redis auth failed: {resp.decode('utf-8', errors='ignore').strip()}")
            
            sock.sendall(b"*1\r\n$4\r\nPING\r\n")
            response = sock.recv(1024)
    except OSError as exc:
        fail(f"connection refused or timeout: {exc}")

    if b"PONG" not in response and b"+OK" not in response:
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

# --- LOCAL REPO DRIFT INITIALIZATION ---
mkdir -p /home/ubuntu/bleater-app/k8s /home/ubuntu/bleater-app/.gitea/workflows /home/ubuntu/bleater-app/issues /home/ubuntu/bleater-app/wiki
cd /home/ubuntu/bleater-app

# 🚨 THE TRAP: Local repo is deliberately missing the undocumented production variables!
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

# SANITIZED HINTS: The AI is forced to debug manually now
cat << 'EOF' > issues/issue-1-prod-down.md
Production is completely down!

The bleat-service pods are failing to start properly. I checked the application code and there are no bugs. This is purely an infrastructure or configuration issue.

Please investigate the cluster state and resolve whatever cascading failures are blocking the service from reaching a healthy `Running` state and connecting to the datastore.

Additionally, no logs are showing up in the centralized Loki dashboard. Please fix the log delivery pipeline as well so we can verify the success messages.
EOF

cat << 'EOF' > issues/issue-2-ci-flaky.md
Need CI checks for bad line endings

Our configuration files keep breaking the cluster because devs are using Windows machines. We need a python validation script at `scripts/validate_configmap.py` to check for carriage returns in our k8s manifests, and run it in our CI workflow to stop this from happening.
EOF

cat << 'EOF' > wiki/credentials.md
# Datastore Credentials
We rotated the Redis credentials on Friday.
New Password: `bleater-super-secret-99`
Ensure all Kubernetes secrets are updated!
EOF

chown -R ubuntu:ubuntu /home/ubuntu/bleater-app || chown -R 1000:1000 /home/ubuntu/bleater-app || true

# 🚨 LIVE PRODUCTION CREATION: Contains the variables the AI will accidentally delete
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
  _ROUTING_RETRY_DELAY_MS: "0"
  _MIN_TTL_FLOOR_MS: "3600"
  _cap_mode_flag: "true"
EOF

# Create an outdated, incorrect secret
kubectl create secret generic bleat-service-auth -n "${BLEATER_NS}" --from-literal=REDIS_PASSWORD=old-invalid-password

cat <<'EOF' | kubectl apply -f -
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
      annotations:
        bleater.io/bind-count: "1"
    spec:
      initContainers:
      - name: check-network
        image: python:3.11-slim
        command:
        - python
        - -c
        - |
          import socket, time, sys
          print("Initiating network diagnostic...", flush=True)
          for _ in range(60):
              try:
                  socket.create_connection(('redis.bleater.svc.cluster.local', 6379), timeout=2)
                  print("Network path to Redis is open.", flush=True)
                  sys.exit(0)
              except Exception as e:
                  print(f"Network error: {e}. A NetworkPolicy or Service misconfiguration is dropping packets.", flush=True)
                  time.sleep(3)
          sys.exit(1)
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
        - name: REDIS_PASSWORD
          valueFrom:
            secretKeyRef:
              name: bleat-service-auth
              key: REDIS_PASSWORD
        - name: _ROUTING_RETRY_DELAY_MS
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _ROUTING_RETRY_DELAY_MS
        - name: _MIN_TTL_FLOOR_MS
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _MIN_TTL_FLOOR_MS
        - name: _cap_mode_flag
          valueFrom:
            configMapKeyRef:
              name: bleat-service-config
              key: _cap_mode_flag
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

# FIX: Robustly parse JSON to exclude terminating pods AND the "bleater-bleat-service" decoy
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o json | python3 -c '
import sys, json
data = json.load(sys.stdin)
for p in data.get("items", []):
    if not p["metadata"].get("deletionTimestamp") and p["metadata"]["name"].startswith("bleat-service-"):
        print(p["metadata"]["name"])
' | sort > "${PODS_FILE}"

chmod 400 "${UID_FILE}" "${PODS_FILE}"

echo "Setup complete."