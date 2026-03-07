#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    echo "Waiting for k3s... (${ELAPSED}s elapsed)"
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

echo "k3s is ready"

BLEATER_NS="bleater"
LOG_NS="logging"
UID_FILE="/tmp/bleat-service-deployment-uid"
PODS_FILE="/tmp/bleat-service-original-pods"

kubectl create namespace "${BLEATER_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "${LOG_NS}" --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
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
                    if not line:
                        return
                    if b"PING" in line.upper():
                        self.wfile.write(b"+PONG\r\n")
                        self.wfile.flush()
                        return
            except Exception:
                return


    class Server(socketserver.ThreadingTCPServer):
        allow_reuse_address = True


    Server(("", 6379), Handler).serve_forever()
EOF

cat <<'EOF' | kubectl apply -f -
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
    targetPort: 6379
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-script
  namespace: logging
data:
  server.py: |
    import json
    import os
    import re
    import urllib.parse
    from http.server import BaseHTTPRequestHandler, HTTPServer

    STORE = "/data/logs.jsonl"
    os.makedirs("/data", exist_ok=True)
    open(STORE, "a", encoding="utf-8").close()


    def load_entries():
        entries = []
        with open(STORE, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return entries


    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            return

        def _send(self, status, payload):
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            if self.path != "/loki/api/v1/push":
                self._send(404, {"status": "error", "error": "not found"})
                return

            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length).decode("utf-8"))

            with open(STORE, "a", encoding="utf-8") as handle:
                for stream in payload.get("streams", []):
                    labels = stream.get("stream", {})
                    for ts, message in stream.get("values", []):
                        handle.write(
                            json.dumps(
                                {"ts": str(ts), "labels": labels, "message": message}
                            )
                            + "\n"
                        )

            self._send(204, {})

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/ready":
                self._send(200, {"status": "ready"})
                return

            if parsed.path == "/debug/logs":
                self._send(200, {"entries": load_entries()})
                return

            if parsed.path != "/loki/api/v1/query":
                self._send(404, {"status": "error", "error": "not found"})
                return

            query = urllib.parse.parse_qs(parsed.query).get("query", [""])[0]
            app_match = re.search(r'app=\"([^\"]+)\"', query)
            level_match = re.search(r'level=\"([^\"]+)\"', query)
            app = app_match.group(1) if app_match else None
            level = level_match.group(1) if level_match else None

            result_map = {}
            for entry in load_entries():
                labels = entry.get("labels", {})
                if app and labels.get("app") != app:
                    continue
                if level and labels.get("level") != level:
                    continue
                key = tuple(sorted(labels.items()))
                if key not in result_map:
                    result_map[key] = {"stream": labels, "values": []}
                result_map[key]["values"].append([entry.get("ts", "0"), entry.get("message", "")])

            self._send(
                200,
                {
                    "status": "success",
                    "data": {
                        "resultType": "streams",
                        "result": list(result_map.values()),
                    },
                },
            )


    HTTPServer(("", 3100), Handler).serve_forever()
EOF

cat <<'EOF' | kubectl apply -f -
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
        volumeMounts:
        - name: app
          mountPath: /app
        - name: data
          mountPath: /data
        readinessProbe:
          httpGet:
            path: /ready
            port: 3100
          initialDelaySeconds: 2
          periodSeconds: 3
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
    targetPort: 3100
EOF

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-script
  namespace: bleater
data:
  app.py: |
    import json
    import os
    import socket
    import sys
    import time
    import urllib.parse
    import urllib.request
    from http.server import BaseHTTPRequestHandler, HTTPServer

    REDIS_URL = os.environ.get("REDIS_URL", "")
    LOKI_URL = os.environ.get("LOKI_URL", "http://loki-gateway.logging.svc.cluster.local:3100")
    POD_NAME = os.environ.get("HOSTNAME", "bleat-service")


    def push_log(level, message):
        payload = {
            "streams": [
                {
                    "stream": {"app": "bleat-service", "level": level, "pod": POD_NAME},
                    "values": [[str(int(time.time() * 1000000000)), message]],
                }
            ]
        }
        body = json.dumps(payload).encode("utf-8")
        request = urllib.request.Request(
            LOKI_URL.rstrip("/") + "/loki/api/v1/push",
            data=body,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=5):
                pass
        except Exception:
            pass
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
        def log_message(self, format, *args):
            return

        def do_GET(self):
            if self.path == "/ready":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"OK")
                return

            if self.path == "/debug/env":
                self.send_response(200)
                self.end_headers()
                self.wfile.write(repr(REDIS_URL).encode("utf-8"))
                return

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"bleat-service")


    HTTPServer(("", 8080), Handler).serve_forever()
EOF

mkdir -p "${SCRIPT_DIR}/k8s" "${SCRIPT_DIR}/.gitea/workflows"

cat <<'EOF' > "${SCRIPT_DIR}/k8s/bleat-service-configmap.yaml"
apiVersion: v1
kind: ConfigMap
metadata:
  name: bleat-service-config
  namespace: bleater
data:
  REDIS_URL: "redis://redis.bleater.svc.cluster.local:6379/0\r"
EOF

cat <<'EOF' > "${SCRIPT_DIR}/.gitea/workflows/bleat-ci.yaml"
name: bleat-ci

on:
  push:
  pull_request:

jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Run unit tests
        run: echo "tests passed"
EOF

kubectl apply -f "${SCRIPT_DIR}/k8s/bleat-service-configmap.yaml"

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
kubectl rollout status deployment/redis -n "${BLEATER_NS}" --timeout=180s
kubectl rollout status deployment/loki-gateway -n "${LOG_NS}" --timeout=180s

echo "Waiting for bleat-service pods to appear in broken state..."
for _ in $(seq 1 30); do
    if kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service --no-headers 2>/dev/null | grep -q .; then
        break
    fi
    sleep 2
done

kubectl get deployment bleat-service -n "${BLEATER_NS}" -o jsonpath='{.metadata.uid}' > "${UID_FILE}"
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > "${PODS_FILE}"
chmod 400 "${UID_FILE}" "${PODS_FILE}"

echo "Current ConfigMap value (normal views may hide carriage returns):"
kubectl get configmap bleat-service-config -n "${BLEATER_NS}" -o jsonpath='{.data.REDIS_URL}' || true
echo

echo "Initial bleat-service pod status:"
kubectl get pods -n "${BLEATER_NS}" -l app=bleat-service -o wide || true

echo "Recent bleat-service logs:"
kubectl logs -n "${BLEATER_NS}" deployment/bleat-service --tail=10 || true

echo "Setup complete. The live ConfigMap is corrupted and the checked-out manifest plus CI workflow need repair."
