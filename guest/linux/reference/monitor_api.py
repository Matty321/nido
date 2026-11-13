
#!/usr/bin/env python3

import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from datetime import datetime, timezone
import os

from monitor import read_cpu, read_memory, read_disk


class MonitorHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path != "/api/status":
            self.send_error(404)
            return

        cpu = read_cpu()
        memory = read_memory()
        disk = read_disk()

        alerts = []

        if cpu["status"] != "OK":
            alerts.append("CPU elevata")
        if memory["status"] != "OK":
            alerts.append("RAM disponibile ridotta")
        if disk["status"] != "OK":
            alerts.append("Disco quasi pieno")

        data = {
            "agent": "Nido AI Monitor",
            "version": "2.0",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "hostname": os.uname().nodename,
            "cpu": cpu,
            "memory": memory,
            "disk": disk,
            "alerts": alerts,
            "status": "WARNING" if alerts else "OK"
        }

        body = json.dumps(data).encode("utf-8")

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8080), MonitorHandler)
    print("Nido Monitor API: http://127.0.0.1:8080/api/status")
    server.serve_forever()
