#!/bin/bash

set -euo pipefail

# =========================================
# SHELL DEPLOYER - FINAL WORKING VERSION
# =========================================

# =========================
# COLORS
# =========================
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m'

# =========================
# VARIABLES
# =========================
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || echo "")"
REGION="us-central1"
RAND=$(openssl rand -hex 3)
SERVICE_NAME="rafael-${RAND}"
DOMAIN="www.google.com"
BUILD_DIR=$(mktemp -d)

trap 'rm -rf "$BUILD_DIR"' EXIT

# =========================
# CHECK PROJECT
# =========================
clear
echo -e "${CYAN}=========================================${NC}"
echo -e "${GREEN}   DEPLOYER - FINAL FIX VERSION${NC}"
echo -e "${CYAN}=========================================${NC}"

if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}❌ Walang naka-set na Google Cloud Project${NC}"
    echo "Patakbuhin muna: gcloud config set project IYONG_PROJECT_ID"
    exit 1
fi

echo -e "${GREEN}✅ Project:${NC} $PROJECT_ID"
echo ""

# =========================
# ENABLE APIS
# =========================
echo -e "${CYAN}➡️ Pinapagana ang mga kinakailangang serbisyo...${NC}"
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    --quiet

# =========================
# SETTINGS
# =========================
echo ""
echo -e "${YELLOW}⚠️ Piliin ang Setting (Mas matatag ang Instance-Based):${NC}"
echo "1) Request-Based"
echo "2) Instance-Based ✅ REKOMENDADO"
read -p "Piliin [1-2]: " BILL

if [ "$BILL" = "2" ]; then
    BILL_FLAGS="--no-cpu-throttling --cpu-boost"
    MEM="2Gi"
    CPU="1"
else
    BILL_FLAGS="--cpu-throttling"
    MEM="1Gi"
    CPU="1"
fi

CONCURRENCY="1000"
TIMEOUT="3600"
MIN_INST="0"
MAX_INST="2"

# =========================
# BUILD FILES
# =========================
cd "$BUILD_DIR" || exit 1

# ✅ CONFIG.JSON
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "trojan",
      "port": 10001,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": { "clients": [{"password": "rafaeltv"}] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/trojan-rafael?ed=2180" }
      }
    },
    {
      "tag": "vless",
      "port": 10002,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{"id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1"}], "decryption": "none" },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless-rafael?ed=2180" }
      }
    },
    {
      "tag": "httpupgrade",
      "port": 11004,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{"id": "15f7e8ea-7b56-45d4-93af-31f3c592fdf1"}], "decryption": "none" },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": { "path": "/httpupgrade-rafael?ed=2180", "host": "$DOMAIN" }
      }
    }
  ],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
EOF

# ✅ NGINX.CONF
cat > nginx.conf <<EOF
worker_processes auto;
events { worker_connections 1024; }
http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 300;
    client_max_body_size 0;

    map \$http_upgrade \$connection_upgrade { default upgrade; '' close; }

    server {
        listen 8080;

        location / {
            proxy_pass https://$DOMAIN;
            proxy_set_header Host $DOMAIN;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        location /trojan-rafael {
            proxy_pass http://127.0.0.1:10001;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 3600s;
        }

        location /vless-rafael {
            proxy_pass http://127.0.0.1:10002;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 3600s;
        }

        location /httpupgrade-rafael {
            proxy_pass http://127.0.0.1:11004;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_read_timeout 3600s;
        }
    }
}
EOF

# ✅ ENTRYPOINT
cat > entrypoint.sh <<EOF
#!/bin/sh
set -e
/usr/local/bin/xray run -c /etc/xray.json &
sleep 4
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
EOF
chmod +x entrypoint.sh

# ✅ DOCKERFILE
cat > Dockerfile <<EOF
FROM alpine:3.20 AS xray
RUN apk add --no-cache curl unzip
WORKDIR /tmp
RUN curl -sL -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip \
    && unzip xray.zip xray && chmod +x xray && mv xray /usr/local/bin/

FROM openresty/openresty:alpine
RUN apk add --no-cache ca-certificates
COPY --from=xray /usr/local/bin/xray /usr/local/bin/xray
COPY config.json /etc/xray.json
COPY nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080
CMD ["/entrypoint.sh"]
EOF

# =========================
# BUILD & DEPLOY
# =========================
echo ""
echo -e "${CYAN}➡️ Gumagawa ng imahe...${NC}"
gcloud builds submit --tag=gcr.io/$PROJECT_ID/$SERVICE_NAME --quiet

echo ""
echo -e "${CYAN}➡️ Nagde-deploy sa Cloud Run...${NC}"
gcloud run deploy $SERVICE_NAME \
    --image gcr.io/$PROJECT_ID/$SERVICE_NAME \
    --platform managed \
    --region $REGION \
    --allow-unauthenticated \
    --port 8080 \
    --memory $MEM \
    --cpu $CPU \
    --concurrency $CONCURRENCY \
    --timeout $TIMEOUT \
    --min-instances $MIN_INST \
    --max-instances $MAX_INST \
    --execution-environment gen2 \
    $BILL_FLAGS \
    --quiet

# =========================
# RESULT
# =========================
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region $REGION --format='value(status.url)' 2>/dev/null || echo "MALI ANG PAGKUHA NG URL")

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}✅ MATAGUMPAY NA NA-DEPLOY!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo -e "URL: ${CYAN}$SERVICE_URL${NC}"
echo ""

echo -e "${YELLOW}--- TROJAN WS ---${NC}"
echo "Address: $SERVICE_URL"
echo "Port: 443"
echo "Path: /trojan-rafael?ed=2180"
echo "Password: rafaeltv"
echo "TLS: ON"
echo ""

echo -e "${YELLOW}--- VLESS WS ---${NC}"
echo "Address: $SERVICE_URL"
echo "Port: 443"
echo "Path: /vless-rafael?ed=2180"
echo "UUID: 15f7e8ea-7b56-45d4-93af-31f3c592fdf1"
echo "Encryption: none"
echo "TLS: ON"
echo ""

echo -e "${YELLOW}--- HTTPUPGRADE ✅ ---${NC}"
echo "Address: $SERVICE_URL"
echo "Port: 443"
echo "Path: /httpupgrade-rafael?ed=2180"
echo "Network: HTTPUpgrade"
echo "UUID: 15f7e8ea-7b56-45d4-93af-31f3c592fdf1"
echo "Encryption: none"
echo "TLS: ON"
echo ""
