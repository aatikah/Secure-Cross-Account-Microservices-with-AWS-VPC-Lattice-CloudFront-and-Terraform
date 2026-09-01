#!/bin/bash
set -ex

dnf update -y
dnf install -y python3 python3-pip
pip3 install flask

mkdir -p /opt/products-service

cat > /opt/products-service/app.py << 'PYEOF'
import os
import uuid
import logging
from datetime import datetime
from flask import Flask, jsonify, request, abort

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PORT = int(os.environ.get("PORT", 8080))

PRODUCTS_DB = {
    "prod-A1": {
        "id": "prod-A1", "name": "Wireless Headphones", "category": "electronics",
        "price": 79.99, "description": "Noise-cancelling over-ear headphones with 30hr battery",
        "stock": 42, "sku": "WH-NC-BLK-001", "tags": ["audio", "wireless"], "active": True,
        "created_at": "2024-01-01T00:00:00Z",
    },
    "prod-B3": {
        "id": "prod-B3", "name": "USB-C Cable 2m", "category": "accessories",
        "price": 12.99, "description": "Braided USB-C to USB-C 100W fast charging cable",
        "stock": 200, "sku": "CBL-USBC-2M", "tags": ["cable", "usb-c"], "active": True,
        "created_at": "2024-01-02T00:00:00Z",
    },
    "prod-C2": {
        "id": "prod-C2", "name": "Mechanical Keyboard", "category": "peripherals",
        "price": 149.00, "description": "TKL mechanical keyboard with Cherry MX Blue switches",
        "stock": 15, "sku": "KB-MECH-TKL-RGB", "tags": ["keyboard", "mechanical"], "active": True,
        "created_at": "2024-01-03T00:00:00Z",
    },
}

VALID_CATEGORIES = ["electronics", "accessories", "peripherals", "clothing", "home", "other"]

@app.before_request
def log_request():
    logger.info("REQUEST method=%s path=%s remote=%s lattice_identity=%s",
        request.method, request.path, request.remote_addr,
        request.headers.get("x-amzn-lattice-identity", "none"))

@app.after_request
def add_headers(response):
    response.headers["X-Service"] = "products-service"
    return response

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "products-service",
                    "timestamp": datetime.utcnow().isoformat() + "Z",
                    "products_count": len(PRODUCTS_DB)}), 200

@app.route("/products", methods=["GET"])
def list_products():
    results = list(PRODUCTS_DB.values())
    category = request.args.get("category")
    active = request.args.get("active")
    q = request.args.get("q", "").lower()
    if category:
        results = [p for p in results if p["category"] == category]
    if active is not None:
        flag = active.lower() in ("true", "1", "yes")
        results = [p for p in results if p["active"] == flag]
    if q:
        results = [p for p in results if q in p["name"].lower() or q in p["description"].lower()]
    results.sort(key=lambda x: x["name"])
    return jsonify({"products": results, "count": len(results)}), 200

@app.route("/products/<product_id>", methods=["GET"])
def get_product(product_id):
    p = PRODUCTS_DB.get(product_id)
    if not p:
        abort(404, description="Product " + product_id + " not found")
    return jsonify(p), 200

@app.route("/products", methods=["POST"])
def create_product():
    body = request.get_json(force=True, silent=True)
    if not body:
        abort(400, description="Request body must be JSON")
    for f in ["name", "price", "category"]:
        if f not in body:
            abort(400, description="Missing required field: " + f)
    if body["category"] not in VALID_CATEGORIES:
        abort(400, description="Invalid category")
    p = {
        "id": "prod-" + uuid.uuid4().hex[:4].upper(),
        "name": body["name"],
        "category": body["category"],
        "price": round(float(body["price"]), 2),
        "description": body.get("description", ""),
        "stock": int(body.get("stock", 0)),
        "sku": body.get("sku", "SKU-" + uuid.uuid4().hex[:8].upper()),
        "tags": body.get("tags", []),
        "active": body.get("active", True),
        "created_at": datetime.utcnow().isoformat() + "Z",
    }
    PRODUCTS_DB[p["id"]] = p
    return jsonify(p), 201

@app.route("/products/<product_id>/stock", methods=["GET"])
def get_stock(product_id):
    p = PRODUCTS_DB.get(product_id)
    if not p:
        abort(404, description="Product " + product_id + " not found")
    return jsonify({"product_id": product_id, "name": p["name"],
                    "stock": p["stock"], "in_stock": p["stock"] > 0}), 200

@app.route("/products/<product_id>/stock", methods=["PUT"])
def update_stock(product_id):
    p = PRODUCTS_DB.get(product_id)
    if not p:
        abort(404, description="Product " + product_id + " not found")
    body = request.get_json(force=True, silent=True) or {}
    if "quantity" not in body:
        abort(400, description="Must provide quantity field")
    delta = int(body["quantity"])
    op = body.get("operation", "set")
    if op == "set":
        p["stock"] = max(0, delta)
    elif op == "add":
        p["stock"] += delta
    elif op == "subtract":
        if p["stock"] < delta:
            abort(409, description="Insufficient stock")
        p["stock"] -= delta
    else:
        abort(400, description="operation must be set, add, or subtract")
    if p["stock"] == 0:
        p["active"] = False
    PRODUCTS_DB[product_id] = p
    return jsonify({"product_id": product_id, "stock": p["stock"], "in_stock": p["stock"] > 0}), 200

@app.errorhandler(400)
def bad_request(e):
    return jsonify({"error": "Bad Request", "message": str(e.description)}), 400

@app.errorhandler(404)
def not_found(e):
    return jsonify({"error": "Not Found", "message": str(e.description)}), 404

@app.errorhandler(409)
def conflict(e):
    return jsonify({"error": "Conflict", "message": str(e.description)}), 409

if __name__ == "__main__":
    logger.info("Starting products-service on port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=False)
PYEOF

cat > /etc/systemd/system/products-service.service << 'SVCEOF'
[Unit]
Description=Products Microservice
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/products-service
ExecStart=/usr/bin/python3 /opt/products-service/app.py
Restart=always
RestartSec=3
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable products-service
systemctl start products-service
