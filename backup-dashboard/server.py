#!/usr/bin/env python3
"""
Backup dashboard server — serves static files + run-backup trigger
"""
import json
import os
import subprocess
import threading
from datetime import datetime, timezone
from flask import Flask, jsonify, send_from_directory, request
from flask_cors import CORS

app = Flask(__name__)
CORS(app)

BASE_DIR  = os.path.dirname(os.path.abspath(__file__))
SCRIPT    = "/opt/homelab-backup/backup-nextcloud.sh"
LOG_FILE  = "/home/luis/backup.log"

backup_lock    = threading.Lock()
backup_running = False

def run_backup_thread():
    global backup_running
    try:
        with open(LOG_FILE, "a") as lf:
            subprocess.run(["bash", SCRIPT], stdout=lf, stderr=subprocess.STDOUT)
    finally:
        backup_running = False

@app.route("/")
def index():
    return send_from_directory(BASE_DIR, "index.html")

@app.route("/<path:filename>")
def static_files(filename):
    return send_from_directory(BASE_DIR, filename)

@app.route("/run-backup", methods=["POST"])
def run_backup():
    global backup_running
    with backup_lock:
        if backup_running:
            return jsonify({"ok": False, "error": "Backup already running"}), 409
        backup_running = True
    t = threading.Thread(target=run_backup_thread, daemon=True)
    t.start()
    return jsonify({
        "ok": True,
        "message": "Backup started",
        "started_at": datetime.now(timezone.utc).isoformat(),
    })

@app.route("/backup-status")
def backup_status():
    return jsonify({"running": backup_running})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081, debug=False)
