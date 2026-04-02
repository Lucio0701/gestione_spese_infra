#!/bin/bash
# =============================================================================
# Gestione Spese - SSL Setup Script
# Configures Let's Encrypt certificates for HTTPS
# Run this AFTER you have a domain pointing to your server
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   SSL Certificate Setup               ${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if domain is provided
if [ -z "$1" ]; then
    echo -e "${RED}Usage: $0 <your-domain.com> <your-email>${NC}"
    echo "Example: $0 spese.example.com admin@example.com"
    exit 1
fi

DOMAIN=$1
EMAIL=${2:-"admin@$DOMAIN"}

echo -e "\n${YELLOW}Domain: $DOMAIN${NC}"
echo -e "${YELLOW}Email: $EMAIL${NC}"

# Check if running on EC2
if [ ! -f /home/ec2-user/app/docker-compose.prod.yml ]; then
    echo -e "${RED}This script must be run on the EC2 server.${NC}"
    exit 1
fi

cd /home/ec2-user/app

# Create certbot directories
mkdir -p certbot/conf certbot/www

# Step 1: Get initial certificate using standalone mode
echo -e "\n${YELLOW}[1/4] Stopping containers temporarily...${NC}"
docker-compose -f docker-compose.prod.yml down || true

echo -e "\n${YELLOW}[2/4] Obtaining SSL certificate...${NC}"
docker run -it --rm \
    -p 80:80 \
    -v "$(pwd)/certbot/conf:/etc/letsencrypt" \
    -v "$(pwd)/certbot/www:/var/www/certbot" \
    certbot/certbot certonly \
    --standalone \
    --email $EMAIL \
    --agree-tos \
    --no-eff-email \
    -d $DOMAIN

# Step 2: Update nginx config for SSL
echo -e "\n${YELLOW}[3/4] Updating nginx configuration...${NC}"

cat > nginx-ssl.conf << EOF
upstream backend_upstream {
    server backend:8080;
}

# Redirect HTTP to HTTPS
server {
    listen 80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }

    location ~ ^/(auth|users|expenses|budgets|goals|documents|analytics)/ {
        proxy_pass http://backend_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}
EOF

# Step 3: Restart with SSL
echo -e "\n${YELLOW}[4/4] Starting containers with SSL...${NC}"
docker-compose -f docker-compose.prod.yml up -d

# Setup auto-renewal cron job
echo -e "\n${YELLOW}Setting up certificate auto-renewal...${NC}"
(crontab -l 2>/dev/null; echo "0 3 * * * docker run --rm -v /home/ec2-user/app/certbot/conf:/etc/letsencrypt -v /home/ec2-user/app/certbot/www:/var/www/certbot certbot/certbot renew --quiet && docker-compose -f /home/ec2-user/app/docker-compose.prod.yml restart frontend") | crontab -

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}   SSL Setup Complete!                  ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Your app is now available at: ${GREEN}https://$DOMAIN${NC}"
echo ""
echo "Certificate will auto-renew every day at 3 AM."
