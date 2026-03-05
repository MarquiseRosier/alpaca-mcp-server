#!/bin/bash

# Deploy Alpaca MCP Server to Google Cloud Run
# Usage: ./deploy-to-gcp.sh [environment] [project-id]
# Example: ./deploy-to-gcp.sh production my-gcp-project

set -e

# Configuration
SERVICE_NAME="robt-alpaca-mcp"
REGION="us-central1"
ENVIRONMENT="${1:-production}"
PROJECT_ID="${2:-}"
IMAGE_TAG="latest"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if gcloud is installed
if ! command -v gcloud &> /dev/null; then
    log_error "gcloud CLI is not installed. Please install it first: https://cloud.google.com/sdk/install"
    exit 1
fi

# Get or set project ID
if [ -z "$PROJECT_ID" ]; then
    PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
    if [ -z "$PROJECT_ID" ]; then
        log_error "No project ID specified and no default project configured"
        log_info "Usage: $0 [environment] [project-id]"
        log_info "Or set a default project: gcloud config set project YOUR_PROJECT_ID"
        exit 1
    fi
fi

log_info "Deploying to project: $PROJECT_ID"
log_info "Service name: $SERVICE_NAME"
log_info "Region: $REGION"
log_info "Environment: $ENVIRONMENT"

# Set the project
gcloud config set project $PROJECT_ID

# Enable required APIs
log_info "Enabling required GCP APIs..."
gcloud services enable cloudbuild.googleapis.com run.googleapis.com artifactregistry.googleapis.com --quiet

# Create Artifact Registry repository if it doesn't exist
REGISTRY_NAME="alpaca-mcp"
REGISTRY_LOCATION="us-central1"
REGISTRY_URL="${REGISTRY_LOCATION}-docker.pkg.dev/${PROJECT_ID}/${REGISTRY_NAME}"

log_info "Setting up Artifact Registry..."
if ! gcloud artifacts repositories describe $REGISTRY_NAME --location=$REGISTRY_LOCATION &>/dev/null; then
    log_info "Creating Artifact Registry repository..."
    gcloud artifacts repositories create $REGISTRY_NAME \
        --repository-format=docker \
        --location=$REGISTRY_LOCATION \
        --description="Alpaca MCP Server Docker images"
else
    log_info "Artifact Registry repository already exists"
fi

# Configure Docker for Artifact Registry
log_info "Configuring Docker authentication..."
gcloud auth configure-docker ${REGISTRY_LOCATION}-docker.pkg.dev --quiet

# Build image name
IMAGE_NAME="${REGISTRY_URL}/${SERVICE_NAME}:${IMAGE_TAG}"
log_info "Building Docker image: $IMAGE_NAME"

# Check if we should use Cloud Build or local build
if [ "$USE_CLOUD_BUILD" = "true" ]; then
    log_info "Using Cloud Build to build the image..."
    gcloud builds submit --tag $IMAGE_NAME .
else
    log_info "Building Docker image locally..."
    # Use the Cloud Run specific Dockerfile if it exists
    if [ -f "Dockerfile.cloudrun" ]; then
        docker build --platform linux/amd64 -f Dockerfile.cloudrun -t $IMAGE_NAME .
    else
        docker build --platform linux/amd64 -t $IMAGE_NAME .
    fi

    log_info "Pushing image to Artifact Registry..."
    docker push $IMAGE_NAME
fi

# Deploy to Cloud Run
log_info "Deploying to Cloud Run..."

# Base deployment command
DEPLOY_CMD="gcloud run deploy $SERVICE_NAME \
    --image $IMAGE_NAME \
    --region $REGION \
    --platform managed \
    --no-allow-unauthenticated \
    --min-instances 0 \
    --max-instances 100 \
    --memory 512Mi \
    --cpu 1 \
    --timeout 300 \
    --concurrency 1000 \
    --port 8000"

# Add environment variables
if [ "$ENVIRONMENT" = "production" ]; then
    log_warning "Deploying to PRODUCTION environment"
    log_info "Make sure you have set the production API keys in Secret Manager"

    # Check if secrets exist in Secret Manager
    if gcloud secrets describe ALPACA_API_KEY &>/dev/null && \
       gcloud secrets describe ALPACA_SECRET_KEY &>/dev/null; then
        DEPLOY_CMD="$DEPLOY_CMD \
            --set-secrets=ALPACA_API_KEY=ALPACA_API_KEY:latest,ALPACA_SECRET_KEY=ALPACA_SECRET_KEY:latest \
            --set-env-vars=ALPACA_PAPER_TRADE=false,DEBUG=false"
    else
        log_error "Production secrets not found in Secret Manager"
        log_info "Please create the secrets first:"
        log_info "  echo -n 'your-api-key' | gcloud secrets create ALPACA_API_KEY --data-file=-"
        log_info "  echo -n 'your-secret-key' | gcloud secrets create ALPACA_SECRET_KEY --data-file=-"
        exit 1
    fi
else
    log_info "Deploying to DEVELOPMENT/STAGING environment (paper trading)"

    # For development, you can use environment variables or secrets
    if [ -n "$ALPACA_API_KEY" ] && [ -n "$ALPACA_SECRET_KEY" ]; then
        DEPLOY_CMD="$DEPLOY_CMD \
            --set-env-vars=ALPACA_API_KEY=$ALPACA_API_KEY,ALPACA_SECRET_KEY=$ALPACA_SECRET_KEY,ALPACA_PAPER_TRADE=true,DEBUG=true"
    else
        log_warning "ALPACA_API_KEY and ALPACA_SECRET_KEY environment variables not set"
        log_info "Using Secret Manager for development credentials..."

        if gcloud secrets describe ALPACA_API_KEY_DEV &>/dev/null && \
           gcloud secrets describe ALPACA_SECRET_KEY_DEV &>/dev/null; then
            DEPLOY_CMD="$DEPLOY_CMD \
                --set-secrets=ALPACA_API_KEY=ALPACA_API_KEY_DEV:latest,ALPACA_SECRET_KEY=ALPACA_SECRET_KEY_DEV:latest \
                --set-env-vars=ALPACA_PAPER_TRADE=true,DEBUG=true"
        else
            log_error "Development secrets not found in Secret Manager and environment variables not set"
            log_info "Please either:"
            log_info "  1. Set environment variables: export ALPACA_API_KEY=... && export ALPACA_SECRET_KEY=..."
            log_info "  2. Create secrets in Secret Manager:"
            log_info "     echo -n 'your-api-key' | gcloud secrets create ALPACA_API_KEY_DEV --data-file=-"
            log_info "     echo -n 'your-secret-key' | gcloud secrets create ALPACA_SECRET_KEY_DEV --data-file=-"
            exit 1
        fi
    fi
fi

# Execute deployment
eval $DEPLOY_CMD

if [ $? -eq 0 ]; then
    log_info "Deployment successful!"

    # Get the service URL
    SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region $REGION --format 'value(status.url)')
    log_info "Service URL: $SERVICE_URL"

    # Get service details
    log_info "Service details:"
    gcloud run services describe $SERVICE_NAME --region $REGION --format 'table(
        metadata.name,
        spec.template.spec.containers[0].image,
        spec.template.metadata.annotations.autoscaling.knative.dev/minScale,
        spec.template.metadata.annotations.autoscaling.knative.dev/maxScale,
        status.url
    )'

    log_info "To view logs:"
    log_info "  gcloud logs read --project=$PROJECT_ID --service=$SERVICE_NAME"

    log_info "To update environment variables:"
    log_info "  gcloud run services update $SERVICE_NAME --region $REGION --update-env-vars KEY=VALUE"

    log_info "To manage secrets:"
    log_info "  gcloud secrets list"
    log_info "  gcloud secrets versions list SECRET_NAME"
else
    log_error "Deployment failed!"
    exit 1
fi