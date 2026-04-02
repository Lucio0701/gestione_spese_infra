#!/bin/bash
# =============================================================================
# Gestione Spese - Deploy Script
# Builds and pushes Docker images to ECR, then deploys to EC2
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION="eu-south-1"
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/infra/terraform"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   Gestione Spese - Deploy Script      ${NC}"
echo -e "${GREEN}========================================${NC}"

# Step 1: Get Terraform outputs
echo -e "\n${YELLOW}[1/6] Getting Terraform outputs...${NC}"
cd "$TERRAFORM_DIR"

if ! terraform output > /dev/null 2>&1; then
    echo -e "${RED}Error: Terraform not initialized or no state found.${NC}"
    echo "Run 'terraform init && terraform apply' first."
    exit 1
fi

AWS_ACCOUNT_ID=$(terraform output -raw aws_account_id)
ECR_BACKEND_URL=$(terraform output -raw ecr_backend_url)
ECR_FRONTEND_URL=$(terraform output -raw ecr_frontend_url)
SERVER_IP=$(terraform output -raw server_public_ip)

echo "AWS Account: $AWS_ACCOUNT_ID"
echo "Backend ECR: $ECR_BACKEND_URL"
echo "Frontend ECR: $ECR_FRONTEND_URL"
echo "Server IP: $SERVER_IP"

# Step 2: Login to ECR
echo -e "\n${YELLOW}[2/6] Logging in to ECR...${NC}"
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

# Step 3: Build backend image
echo -e "\n${YELLOW}[3/6] Building backend image...${NC}"
cd "$PROJECT_ROOT/backend"

# Build for ARM64 (t4g instance)
docker buildx build \
    --platform linux/arm64 \
    -t "$ECR_BACKEND_URL:latest" \
    -f Dockerfile \
    --push \
    .

echo -e "${GREEN}Backend image pushed successfully!${NC}"

# Step 4: Build frontend image
echo -e "\n${YELLOW}[4/6] Building frontend image...${NC}"
cd "$PROJECT_ROOT/frontend"

# API URL will be relative (proxied through nginx)
docker buildx build \
    --platform linux/arm64 \
    -t "$ECR_FRONTEND_URL:latest" \
    -f Dockerfile.prod \
    --build-arg VITE_API_BASE_URL="" \
    --push \
    .

echo -e "${GREEN}Frontend image pushed successfully!${NC}"

# Step 5: Prepare deployment files
echo -e "\n${YELLOW}[5/6] Preparing deployment files...${NC}"
cd "$PROJECT_ROOT/infra"

# Create .env file for production
cat > .env.prod << EOF
# ECR Image URLs
BACKEND_IMAGE_URL=$ECR_BACKEND_URL
FRONTEND_IMAGE_URL=$ECR_FRONTEND_URL

# Database password (CHANGE THIS!)
DB_PASSWORD=your-secure-db-password-change-me

# JWT Secret (CHANGE THIS! Generate with: openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)
EOF

echo -e "${GREEN}.env.prod created. REMEMBER TO CHANGE THE PASSWORDS!${NC}"

# Step 6: Deploy to EC2
echo -e "\n${YELLOW}[6/6] Deploying to EC2...${NC}"
SSH_KEY="$TERRAFORM_DIR/gestione-spese-key.pem"

if [ ! -f "$SSH_KEY" ]; then
    echo -e "${RED}SSH key not found at $SSH_KEY${NC}"
    exit 1
fi

# Copy files to EC2
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
    docker-compose.prod.yml \
    .env.prod \
    ec2-user@$SERVER_IP:/home/ec2-user/app/

# Deploy on EC2
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no ec2-user@$SERVER_IP << 'ENDSSH'
cd /home/ec2-user/app

# Rename env file
mv .env.prod .env

# Login to ECR
aws ecr get-login-password --region eu-south-1 | \
    docker login --username AWS --password-stdin $(grep BACKEND_IMAGE_URL .env | cut -d'=' -f2 | cut -d'/' -f1)

# Pull latest images
docker-compose -f docker-compose.prod.yml pull

# Stop existing containers (if any)
docker-compose -f docker-compose.prod.yml down || true

# Start containers
docker-compose -f docker-compose.prod.yml up -d

# Show status
echo ""
echo "Container status:"
docker-compose -f docker-compose.prod.yml ps
ENDSSH

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}   Deploy completato!                   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "App disponibile su: ${GREEN}http://$SERVER_IP${NC}"
echo -e "SSH: ${YELLOW}ssh -i $SSH_KEY ec2-user@$SERVER_IP${NC}"
echo ""
echo -e "${YELLOW}IMPORTANTE: Modifica le password in /home/ec2-user/app/.env sul server!${NC}"
