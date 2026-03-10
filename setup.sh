# --- BLEAT APP MOCK ---
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
        
        # GUARANTEE: Massive retry loop to survive K8s DNS propogation delays
        for attempt in range(100):
            try:
                # Increased timeout to 10 seconds to handle slow network routes
                urllib.request.urlopen(request, timeout=10)
                print(f"Log successfully pushed to Loki on attempt {attempt+1}", flush=True)
                break
            except Exception as e:
                print(f"Failed to push log to Loki (attempt {attempt+1}): {e}", flush=True)
                time.sleep(2)
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