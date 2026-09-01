#!/bin/bash
set -ex

dnf update -y
dnf install -y python3 python3-pip
pip3 install flask requests boto3 botocore

mkdir -p /opt/consumer

cat > /opt/consumer/app.py << 'PYEOF'
import os
import json
import logging
from datetime import datetime
import boto3
import requests
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.credentials import Credentials
from flask import Flask, jsonify, request, abort

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

PORT                 = int(os.environ.get("PORT", 8080))
ORDERS_SERVICE_DNS   = os.environ.get("ORDERS_SERVICE_DNS", "")
PRODUCTS_SERVICE_DNS = os.environ.get("PRODUCTS_SERVICE_DNS", "")
AWS_REGION           = os.environ.get("AWS_REGION", "us-east-1")


def signed_request(method, url, body=None, params=None):
    session = boto3.Session()
    creds = session.get_credentials().get_frozen_credentials()
    prepared = requests.Request(method, url, params=params).prepare()
    full_url = prepared.url
    aws_req = AWSRequest(method=method, url=full_url, data=body or b"")
    aws_req.context["payload_signing_enabled"] = False
    SigV4Auth(
        Credentials(creds.access_key, creds.secret_key, creds.token),
        "vpc-lattice-svcs",
        AWS_REGION,
    ).add_auth(aws_req)
    headers = dict(aws_req.headers)
    if body:
        headers["Content-Type"] = "application/json"
    resp = requests.request(method=method, url=full_url, headers=headers, data=body, timeout=10)
    resp.raise_for_status()
    return resp.json()


def lattice_get(dns, path, params=None):
    logger.info("Lattice GET %s%s", dns, path)
    return signed_request("GET", "http://" + dns + path, params=params)


def lattice_post(dns, path, body):
    logger.info("Lattice POST %s%s", dns, path)
    return signed_request("POST", "http://" + dns + path, body=json.dumps(body).encode())


def lattice_put(dns, path, body):
    logger.info("Lattice PUT %s%s", dns, path)
    return signed_request("PUT", "http://" + dns + path, body=json.dumps(body).encode())


@app.route("/health")
def health():
    return jsonify({
        "status": "healthy",
        "service": "storefront-consumer",
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "config": {
            "orders_dns": ORDERS_SERVICE_DNS,
            "products_dns": PRODUCTS_SERVICE_DNS,
        },
    }), 200


@app.route("/diagnostic")
def diagnostic():
    results = {}
    for name, dns in [("orders", ORDERS_SERVICE_DNS), ("products", PRODUCTS_SERVICE_DNS)]:
        if not dns:
            results[name] = {"status": "not_configured"}
            continue
        try:
            resp = lattice_get(dns, "/health")
            results[name] = {"status": "ok", "response": resp}
        except requests.HTTPError as e:
            results[name] = {"status": "http_error", "http_status": e.response.status_code}
        except Exception as e:
            results[name] = {"status": "connection_error", "error": str(e)}
    overall = "healthy" if all(r.get("status") == "ok" for r in results.values()) else "degraded"
    return jsonify({"overall": overall, "services": results}), 200 if overall == "healthy" else 503


@app.route("/storefront")
def storefront():
    errors = []
    try:
        products = lattice_get(PRODUCTS_SERVICE_DNS, "/products", params={"active": "true"}).get("products", [])
    except Exception as e:
        products = []
        errors.append("products-service: " + str(e))
    try:
        orders = lattice_get(ORDERS_SERVICE_DNS, "/orders").get("orders", [])
    except Exception as e:
        orders = []
        errors.append("orders-service: " + str(e))
    return jsonify({
        "storefront": {
            "featured_products": products[:6],
            "recent_orders": orders[-3:],
            "product_count": len(products),
            "order_count": len(orders),
        },
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "errors": errors or None,
    }), 200


@app.route("/api/products", methods=["GET"])
def proxy_list_products():
    try:
        return jsonify(lattice_get(PRODUCTS_SERVICE_DNS, "/products", params=dict(request.args))), 200
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503


@app.route("/api/products/<product_id>", methods=["GET"])
def proxy_get_product(product_id):
    try:
        return jsonify(lattice_get(PRODUCTS_SERVICE_DNS, "/products/" + product_id)), 200
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503


@app.route("/api/products/<product_id>/stock", methods=["GET"])
def proxy_get_stock(product_id):
    try:
        return jsonify(lattice_get(PRODUCTS_SERVICE_DNS, "/products/" + product_id + "/stock")), 200
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503


@app.route("/api/orders", methods=["GET"])
def proxy_list_orders():
    try:
        return jsonify(lattice_get(ORDERS_SERVICE_DNS, "/orders", params=dict(request.args))), 200
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503


@app.route("/api/orders", methods=["POST"])
def proxy_create_order():
    body = request.get_json(force=True, silent=True)
    if not body:
        abort(400, description="Request body must be JSON")
    for item in body.get("items", []):
        pid = item.get("product_id")
        qty = item.get("qty", 1)
        if not pid:
            abort(400, description="Each item must have a product_id")
        try:
            stock = lattice_get(PRODUCTS_SERVICE_DNS, "/products/" + pid + "/stock")
            if stock.get("stock", 0) < qty:
                return jsonify({"error": "Insufficient stock", "product_id": pid,
                                "requested": qty, "available": stock.get("stock", 0)}), 409
        except requests.HTTPError as e:
            if e.response.status_code == 404:
                return jsonify({"error": "Product " + pid + " not found"}), 404
            return jsonify({"error": str(e)}), 503
    try:
        result = lattice_post(ORDERS_SERVICE_DNS, "/orders", body)
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503
    for item in body.get("items", []):
        try:
            lattice_put(PRODUCTS_SERVICE_DNS, "/products/" + item["product_id"] + "/stock",
                        {"quantity": item.get("qty", 1), "operation": "subtract"})
        except Exception as e:
            logger.warning("Stock deduction failed for %s: %s", item["product_id"], e)
    return jsonify(result), 201


@app.route("/api/orders/<order_id>", methods=["GET"])
def proxy_get_order(order_id):
    try:
        return jsonify(lattice_get(ORDERS_SERVICE_DNS, "/orders/" + order_id)), 200
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503


@app.route("/api/orders/<order_id>", methods=["PUT"])
def proxy_update_order(order_id):
    body = request.get_json(force=True, silent=True) or {}
    try:
        return jsonify(lattice_put(ORDERS_SERVICE_DNS, "/orders/" + order_id, body)), 200
    except requests.HTTPError as e:
        return jsonify({"error": str(e)}), e.response.status_code
    except Exception as e:
        return jsonify({"error": str(e)}), 503


@app.errorhandler(400)
def bad_request(e):
    return jsonify({"error": "Bad Request", "message": str(e.description)}), 400


@app.errorhandler(404)
def not_found(e):
    return jsonify({"error": "Not Found", "message": str(e.description)}), 404


if __name__ == "__main__":
    logger.info("Starting consumer on port %d | orders=%s | products=%s",
                PORT, ORDERS_SERVICE_DNS, PRODUCTS_SERVICE_DNS)
    app.run(host="0.0.0.0", port=PORT, debug=False)
PYEOF

cat > /etc/systemd/system/consumer.service << SVCEOF
[Unit]
Description=Storefront Consumer App
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/consumer
ExecStart=/usr/bin/python3 /opt/consumer/app.py
Restart=always
RestartSec=3
Environment=PORT=8080
Environment=ORDERS_SERVICE_DNS=${orders_dns}
Environment=PRODUCTS_SERVICE_DNS=${products_dns}
Environment=AWS_REGION=${aws_region}

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable consumer
systemctl start consumer
