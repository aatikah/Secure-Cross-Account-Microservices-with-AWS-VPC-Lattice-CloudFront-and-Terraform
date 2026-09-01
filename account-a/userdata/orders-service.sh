#!/bin/bash
set -ex

dnf update -y
dnf install -y python3 python3-pip
pip3 install flask

mkdir -p /opt/orders-service

cat > /opt/orders-service/app.py << 'PYEOF'
import os
import uuid
import logging
from datetime import datetime
from flask import Flask, jsonify, request, abort

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PORT = int(os.environ.get("PORT", 8080))

ORDERS_DB = {
    "ord-001": {
        "id": "ord-001", "customer_id": "cust-100",
        "items": [
            {"product_id": "prod-A1", "name": "Wireless Headphones", "qty": 1, "price": 79.99},
            {"product_id": "prod-B3", "name": "USB-C Cable 2m", "qty": 2, "price": 12.99},
        ],
        "status": "shipped", "total": 105.97,
        "created_at": "2024-01-15T10:30:00Z", "updated_at": "2024-01-16T08:00:00Z",
    },
    "ord-002": {
        "id": "ord-002", "customer_id": "cust-200",
        "items": [{"product_id": "prod-C2", "name": "Mechanical Keyboard", "qty": 1, "price": 149.00}],
        "status": "processing", "total": 149.00,
        "created_at": "2024-01-17T14:00:00Z", "updated_at": "2024-01-17T14:00:00Z",
    },
}

VALID_STATUSES = ["pending", "processing", "shipped", "delivered", "cancelled"]

@app.before_request
def log_request():
    logger.info("REQUEST method=%s path=%s remote=%s lattice_identity=%s",
        request.method, request.path, request.remote_addr,
        request.headers.get("x-amzn-lattice-identity", "none"))

@app.after_request
def log_response(response):
    response.headers["X-Service"] = "orders-service"
    return response

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "orders-service",
                    "timestamp": datetime.utcnow().isoformat() + "Z"}), 200

@app.route("/orders", methods=["GET"])
def list_orders():
    results = list(ORDERS_DB.values())
    cid = request.args.get("customer_id")
    status = request.args.get("status")
    if cid:
        results = [o for o in results if o["customer_id"] == cid]
    if status:
        results = [o for o in results if o["status"] == status]
    return jsonify({"orders": results, "count": len(results)}), 200

@app.route("/orders/<order_id>", methods=["GET"])
def get_order(order_id):
    order = ORDERS_DB.get(order_id)
    if not order:
        abort(404, description="Order " + order_id + " not found")
    return jsonify(order), 200

@app.route("/orders", methods=["POST"])
def create_order():
    body = request.get_json(force=True, silent=True)
    if not body:
        abort(400, description="Request body must be JSON")
    for f in ["customer_id", "items"]:
        if f not in body:
            abort(400, description="Missing required field: " + f)
    items = body["items"]
    if not isinstance(items, list) or not items:
        abort(400, description="items must be a non-empty list")
    total = sum(i.get("price", 0) * i.get("qty", 1) for i in items)
    order = {
        "id": "ord-" + uuid.uuid4().hex[:6],
        "customer_id": body["customer_id"],
        "items": items,
        "status": "pending",
        "total": round(total, 2),
        "created_at": datetime.utcnow().isoformat() + "Z",
        "updated_at": datetime.utcnow().isoformat() + "Z",
    }
    ORDERS_DB[order["id"]] = order
    return jsonify(order), 201

@app.route("/orders/<order_id>", methods=["PUT"])
def update_order(order_id):
    order = ORDERS_DB.get(order_id)
    if not order:
        abort(404, description="Order " + order_id + " not found")
    body = request.get_json(force=True, silent=True) or {}
    new_status = body.get("status")
    if new_status:
        if new_status not in VALID_STATUSES:
            abort(400, description="Invalid status")
        order["status"] = new_status
    order["updated_at"] = datetime.utcnow().isoformat() + "Z"
    ORDERS_DB[order_id] = order
    return jsonify(order), 200

@app.route("/orders/<order_id>", methods=["DELETE"])
def cancel_order(order_id):
    order = ORDERS_DB.get(order_id)
    if not order:
        abort(404, description="Order " + order_id + " not found")
    if order["status"] in ["shipped", "delivered"]:
        abort(409, description="Cannot cancel order with status: " + order["status"])
    order["status"] = "cancelled"
    order["updated_at"] = datetime.utcnow().isoformat() + "Z"
    ORDERS_DB[order_id] = order
    return jsonify({"message": "Order " + order_id + " cancelled", "order": order}), 200

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
    logger.info("Starting orders-service on port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=False)
PYEOF

cat > /etc/systemd/system/orders-service.service << 'SVCEOF'
[Unit]
Description=Orders Microservice
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/orders-service
ExecStart=/usr/bin/python3 /opt/orders-service/app.py
Restart=always
RestartSec=3
Environment=PORT=8080

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable orders-service
systemctl start orders-service
