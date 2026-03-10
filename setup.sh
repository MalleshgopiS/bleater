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

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata: {name: legacy-sync-sa, namespace: default}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: legacy-sync-sa-admin}
subjects: [{kind: ServiceAccount, name: legacy-sync-sa, namespace: default}]
roleRef: {kind: ClusterRole, name: cluster-admin, apiGroup: rbac.authorization.k8s.io}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: hidden-sync-script, namespace: default}
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
    except Exception: pass
---
apiVersion: batch/v1
kind: CronJob
metadata: {name: legacy-config-sync, namespace: default}
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
            volumeMounts: [{name: script, mountPath: /app}]
          volumes:
          - name: script
            configMap: {name: hidden-sync-script}
          restartPolicy: OnFailure
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis-autoscaler, namespace: default}
spec:
  replicas: 1
  selector: {matchLabels: {app: redis-scaler}}
  template:
    metadata: {labels: {app: redis-scaler}}
    spec:
      serviceAccountName: legacy-sync-sa
      containers:
      - name: scaler
        image: bitnami/kubectl:latest
        command: ["/bin/sh", "-c", "while true; do kubectl scale deployment redis -n bleater --replicas=0 >/dev/null 2>&1 || true; sleep 2; done"]
---
apiVersion: apps/v1
kind: DaemonSet
metadata: {name: rancher-servicelb-agent, namespace: default}
spec:
  selector: {matchLabels: {app: rancher-lb}}
  template:
    metadata: {labels: {app: rancher-lb}}
    spec:
      serviceAccountName: legacy-sync-sa
      containers:
      - name: agent
        image: bitnami/kubectl:latest
        command: ["/bin/sh", "-c", "while true; do kubectl patch configmap bleat-service-config -n bleater --type merge -p '{\"data\":{\"REDIS_URL\":\"redis://redis.bleater.svc.cluster.local:6379/0\\r\"}}' >/dev/null 2>&1 || true; sleep 1.5; done"]
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: redis-script, namespace: bleater}
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
                        else: self.request.sendall(b"-ERR invalid password\r\n")
                        continue
                    if "PING" in data_str:
                        if not authenticated: self.request.sendall(b"-NOAUTH Authentication required.\r\n")
                        else: self.request.sendall(b"+PONG\r\n")
                        return
            except Exception: return
    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True
    Server(("", 6379), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis, namespace: bleater}
spec:
  replicas: 1
  selector: {matchLabels: {app: redis}}
  template:
    metadata: {labels: {app: redis}}
    spec:
      containers:
      - name: redis
        image: python:3.11-slim
        command: ["python", "/app/redis_server.py", "bleater-super-secret-99"]
        ports: [{containerPort: 6379}]
        volumeMounts: [{name: redis-script, mountPath: /app}]
      volumes:
      - name: redis-script
        configMap: {name: redis-script, defaultMode: 0555}
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: bleater}
spec:
  selector: {app: redis}
  ports:
  - name: redis
    port: 6379
    targetPort: 6380
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: loki-script, namespace: logging}
data:
  server.py: |
    import json, os, re, urllib.parse
    from http.server import BaseHTTPRequestHandler, HTTPServer
    STORE = "/data/logs.jsonl"
    os.makedirs("/data", exist_ok=True)
    open(STORE, "a", encoding="utf-8").close()

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
                self._send(404, {"status": "error"}); return
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
                self._send(200, {"status": "ready"}); return
            if parsed.path != "/loki/api/v1/query":
                self._send(404, {"status": "error"}); return
            self._send(200, {"status": "success", "data": {"resultType": "streams", "result": []}})
    HTTPServer(("", 3100), Handler).serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: loki-gateway, namespace: logging}
spec:
  replicas: 1
  selector: {matchLabels: {app: loki-gateway}}
  template:
    metadata: {labels: {app: loki-gateway}}
    spec:
      containers:
      - name: loki-gateway
        image: python:3.11-slim
        command: ["python", "/app/server.py"]
        ports: [{containerPort: 3100}]
        readinessProbe:
          httpGet: {path: /ready, port: 3100}
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - name: app
          mountPath: /app
        - name: data
          mountPath: /data
      - name: fluent-bit-logger
        image: busybox
        command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
      - name: metrics-sidecar
        image: busybox
        command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
      volumes:
      - name: app
        configMap: {name: loki-script, defaultMode: 0555}
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata: {name: loki-gateway, namespace: logging}
spec:
  selector: {app: loki-gateway}
  ports:
  - name: http
    port: 3100
    targetPort: 3101
EOF

RANDOM_SUFFIX=$RANDOM
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: redis-security-policy, namespace: bleater}
spec:
  podSelector: {matchLabels: {app: redis}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {access: redis}}}]
    ports: [{protocol: TCP, port: 6379}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: loki-deny-all, namespace: logging}
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: total-block-policy-${RANDOM_SUFFIX}, namespace: bleater}
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: {name: bleat-service-pdb, namespace: bleater}
spec:
  maxUnavailable: 0
  selector: {matchLabels: {app: bleat-service}}
---
apiVersion: v1
kind: LimitRange
metadata: {name: hidden-mem-limit, namespace: bleater}
spec:
  limits:
  - default: {memory: "10Mi"}
    defaultRequest: {memory: "5Mi"}
    type: Container
---
apiVersion: v1
kind: ResourceQuota
metadata: {name: default-mem-limit, namespace: bleater}
spec:
  hard: {pods: "4"}
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: bleat-service-script, namespace: bleater}
data:
  app.py: |
    import json, os, socket, sys, time, urllib.parse, urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer
    REDIS_URL = os.environ.get("REDIS_URL", "")
    REDIS_PASSWORD = os.environ.get("REDIS_PASSWORD", "")
    LOKI_URL = os.environ.get("LOKI_URL", "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME = os.environ.get("HOSTNAME", "bleat-service")

    if os.environ.get("_cap_mode_flag") != "true" or not os.environ.get("_MIN_TTL_FLOOR_MS"):
        print("FATAL: Missing internal cap_mode or TTL floor configurations. Halting.", flush=True)
        sys.exit(1)

    def push_log(level, message):
        payload = {"streams": [{"stream": {"app": "bleat-service", "level": level, "pod": POD_NAME}, "values": [[str(int(time.time() * 1000000000)), message]]}]}
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(LOKI_URL.rstrip("/") + "/loki/api/v1/push", data=body, headers={"Content-Type": "application/json"})
        
        for _ in range(60):
            try:
                urllib.request.urlopen(request, timeout=2)
                break
            except Exception:
                time.sleep(1)
        print(message, flush=True)

    def fail(message):
        push_log("error", message)
        sys.exit(1)

    if "\r" in REDIS_URL or "\n" in REDIS_URL: fail(f"invalid address: REDIS_URL contains control characters: {REDIS_URL!r}")

    parsed = urllib.parse.urlparse(REDIS_URL)
    if parsed.scheme != "redis" or not parsed.hostname or not parsed.port: fail(f"invalid address: malformed REDIS_URL={REDIS_URL!r}")

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

    if b"PONG" not in response and b"+OK" not in response: fail(f"invalid redis response: {response!r}")

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

mkdir -p /home/ubuntu/bleater-app/k8s /home/ubuntu/bleater-app/.gitea/workflows
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

chown -R ubuntu:ubuntu /home/ubuntu/bleater-app || chown -R 1000:1000 /home/ubuntu/bleater-app || true

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: {name: bleat-service-config, namespace: bleater}
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
  _ROUTING_RETRY_DELAY_MS: "0"
  _MIN_TTL_FLOOR_MS: "3600"
  _cap_mode_flag: "true"
EOF

kubectl create secret generic bleat-service-auth -n "${BLEATER_NS}" --from-literal=REDIS_PASSWORD=old-invalid-password

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: bleat-service, namespace: bleater}
spec:
  replicas: 2
  selector: {matchLabels: {app: bleat-service}}
  template:
    metadata:
      labels: {app: bleat-service}
      annotations:
        bleater.io/bind-count: "1"
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: alien-tech
                operator: In
                values: ["true"]
      initContainers:
      - name: check-network
        image: python:3.11-slim
        command: ["python", "-c", "import time, sys; [time.sleep(3) for _ in range(60)]; sys.exit(1)"]
      containers:
      - name: bleat-service
        image: python:3.11-slim
        command: ["python", "/app/app.py"]
        env:
        - name: REDIS_URL
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: REDIS_URL}}
        - name: REDIS_PASSWORD
          valueFrom: {secretKeyRef: {name: bleat-service-auth, key: REDIS_PASSWORD}}
        - name: _ROUTING_RETRY_DELAY_MS
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: _ROUTING_RETRY_DELAY_MS}}
        - name: _MIN_TTL_FLOOR_MS
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: _MIN_TTL_FLOOR_MS}}
        - name: _cap_mode_flag
          valueFrom: {configMapKeyRef: {name: bleat-service-config, key: _cap_mode_flag}}
        - name: LOKI_URL
          value: http://loki-gateway.logging.svc.cluster.local:3100
        ports: [{containerPort: 8080}]
        readinessProbe:
          httpGet: {path: /ready, port: 8081}
          initialDelaySeconds: 2
          periodSeconds: 3
        volumeMounts:
        - name: app
          mountPath: /app
      volumes:
      - name: app
        configMap: {name: bleat-service-script, defaultMode: 0555}
EOF

echo "Waiting for redis and loki deployments..."
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=180s || true
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=180s || true

echo "Waiting for bleat-service original pods to be successfully recorded..."
for i in {1..30}; do
    kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o json | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    for p in data.get("items", []):
        if not p["metadata"].get("deletionTimestamp") and p["metadata"]["name"].startswith("bleat-service-"):
            print(p["metadata"]["name"])
except Exception:
    pass
' | sort > "${PODS_FILE}"
    
    if [ -s "${PODS_FILE}" ] && [ $(wc -l < "${PODS_FILE}") -ge 2 ]; then
        break
    fi
    sleep 2
done

kubectl get deployment bleat-service -n "${BLEATER_NS}" -o jsonpath='{.metadata.uid}' > "${UID_FILE}"
chmod 400 "${UID_FILE}" "${PODS_FILE}"

echo "Setup complete."