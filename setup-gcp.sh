#!/bin/bash

# Quick setup script for GCP deployment prerequisites
# This script helps set up the initial GCP environment for the Alpaca MCP Server

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Alpaca MCP Server - GCP Setup Script${NC}"
echo "======================================"

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check for gcloud CLI
if ! command_exists gcloud; then
    echo -e "${RED}Error: gcloud CLI is not installed${NC}"
    echo "Please install it from: https://cloud.google.com/sdk/install"
    exit 1
fi

# Get or prompt for project ID
if [ -z "$1" ]; then
    CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)
    if [ -n "$CURRENT_PROJECT" ]; then
        echo -e "Current project: ${YELLOW}$CURRENT_PROJECT${NC}"
        read -p "Use this project? (y/n): " USE_CURRENT
        if [ "$USE_CURRENT" = "y" ]; then
            PROJECT_ID=$CURRENT_PROJECT
        else
            read -p "Enter your GCP Project ID: " PROJECT_ID
        fi
    else
        read -p "Enter your GCP Project ID: " PROJECT_ID
    fi
else
    PROJECT_ID=$1
fi

echo -e "${GREEN}Setting up project: $PROJECT_ID${NC}"

# Set the project
gcloud config set project $PROJECT_ID

# Enable required APIs
echo -e "${YELLOW}Enabling required GCP APIs...${NC}"
gcloud services enable \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    --quiet

echo -e "${GREEN}✓ APIs enabled${NC}"

# Create Artifact Registry repository
REGISTRY_NAME="alpaca-mcp"
REGISTRY_LOCATION="us-central1"

echo -e "${YELLOW}Setting up Artifact Registry...${NC}"
if ! gcloud artifacts repositories describe $REGISTRY_NAME --location=$REGISTRY_LOCATION &>/dev/null; then
    gcloud artifacts repositories create $REGISTRY_NAME \
        --repository-format=docker \
        --location=$REGISTRY_LOCATION \
        --description="Alpaca MCP Server Docker images" \
        --quiet
    echo -e "${GREEN}✓ Artifact Registry created${NC}"
else
    echo -e "${GREEN}✓ Artifact Registry already exists${NC}"
fi

# Configure Docker authentication
echo -e "${YELLOW}Configuring Docker authentication...${NC}"
gcloud auth configure-docker ${REGISTRY_LOCATION}-docker.pkg.dev --quiet
echo -e "${GREEN}✓ Docker authentication configured${NC}"

# Set up secrets
echo -e "${YELLOW}Setting up Secret Manager...${NC}"
echo ""
echo "You'll need your Alpaca API keys. Get them from:"
echo -e "${GREEN}https://app.alpaca.markets/dashboard/overview${NC}"
echo ""

# Function to create or update secret
create_or_update_secret() {
    SECRET_NAME=$1
    SECRET_DESC=$2

    echo -e "${YELLOW}Setting up secret: $SECRET_NAME${NC}"

    if gcloud secrets describe $SECRET_NAME &>/dev/null; then
        echo "Secret $SECRET_NAME already exists."
        read -p "Do you want to update it? (y/n): " UPDATE_SECRET
        if [ "$UPDATE_SECRET" = "y" ]; then
            read -s -p "Enter value for $SECRET_DESC: " SECRET_VALUE
            echo ""
            echo -n "$SECRET_VALUE" | gcloud secrets versions add $SECRET_NAME --data-file=- --quiet
            echo -e "${GREEN}✓ Secret updated${NC}"
        else
            echo "Keeping existing secret"
        fi
    else
        read -s -p "Enter value for $SECRET_DESC: " SECRET_VALUE
        echo ""
        echo -n "$SECRET_VALUE" | gcloud secrets create $SECRET_NAME \
            --replication-policy="automatic" \
            --data-file=- \
            --quiet
        echo -e "${GREEN}✓ Secret created${NC}"
    fi
}

# Ask about environment
echo ""
read -p "Setup for production (live trading) or development (paper trading)? (prod/dev): " ENV_TYPE

if [ "$ENV_TYPE" = "prod" ]; then
    echo -e "${RED}WARNING: Setting up PRODUCTION environment for LIVE trading${NC}"
    read -p "Are you sure? (yes/no): " CONFIRM
    if [ "$CONFIRM" = "yes" ]; then
        create_or_update_secret "ALPACA_API_KEY" "Alpaca LIVE API Key"
        create_or_update_secret "ALPACA_SECRET_KEY" "Alpaca LIVE Secret Key"
    else
        echo "Cancelled production setup"
        ENV_TYPE="dev"
    fi
fi

if [ "$ENV_TYPE" = "dev" ] || [ "$ENV_TYPE" != "prod" ]; then
    echo -e "${GREEN}Setting up DEVELOPMENT environment (paper trading)${NC}"
    create_or_update_secret "ALPACA_API_KEY_DEV" "Alpaca PAPER API Key"
    create_or_update_secret "ALPACA_SECRET_KEY_DEV" "Alpaca PAPER Secret Key"
fi

# Grant Cloud Run access to secrets
echo -e "${YELLOW}Configuring IAM permissions...${NC}"
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Function to grant secret access
grant_secret_access() {
    SECRET_NAME=$1
    if gcloud secrets describe $SECRET_NAME &>/dev/null; then
        gcloud secrets add-iam-policy-binding $SECRET_NAME \
            --member="serviceAccount:${SERVICE_ACCOUNT}" \
            --role="roles/secretmanager.secretAccessor" \
            --quiet &>/dev/null
        echo -e "${GREEN}✓ Granted access to $SECRET_NAME${NC}"
    fi
}

grant_secret_access "ALPACA_API_KEY"
grant_secret_access "ALPACA_SECRET_KEY"
grant_secret_access "ALPACA_API_KEY_DEV"
grant_secret_access "ALPACA_SECRET_KEY_DEV"

# Create Cloud Build trigger (optional)
echo ""
read -p "Do you want to set up Cloud Build for automatic deployments? (y/n): " SETUP_BUILD

if [ "$SETUP_BUILD" = "y" ]; then
    echo -e "${YELLOW}Setting up Cloud Build...${NC}"

    # Check if the repository is connected
    REPO_NAME="alpaca-mcp-server"

    if ! gcloud builds triggers list --filter="github.name=$REPO_NAME" --format="value(name)" | grep -q .; then
        echo "Please connect your GitHub repository first:"
        echo "1. Go to: https://console.cloud.google.com/cloud-build/triggers/connect"
        echo "2. Connect your GitHub repository"
        echo "3. Then run this command:"
        echo ""
        echo "gcloud builds triggers create github \\"
        echo "  --repo-name=$REPO_NAME \\"
        echo "  --repo-owner=alpacahq \\"
        echo "  --branch-pattern=^main$ \\"
        echo "  --build-config=cloudbuild.yaml \\"
        echo "  --name=alpaca-mcp-deploy"
    else
        echo -e "${GREEN}✓ Cloud Build trigger already exists${NC}"
    fi
fi

# Summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Project ID: $PROJECT_ID"
echo "Region: us-central1"
echo "Artifact Registry: ${REGISTRY_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_NAME}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Make the deployment script executable:"
echo "   chmod +x deploy-to-gcp.sh"
echo ""
echo "2. Deploy the service:"
if [ "$ENV_TYPE" = "prod" ]; then
    echo "   ./deploy-to-gcp.sh production"
else
    echo "   ./deploy-to-gcp.sh development"
fi
echo ""
echo "3. Monitor your service:"
echo "   gcloud run services list"
echo "   gcloud logs tail --service=robt-alpaca-mcp"
echo ""
echo -e "${GREEN}Happy trading! 🚀${NC}"