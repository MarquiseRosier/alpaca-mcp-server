# Google Cloud Platform Deployment Guide

This guide explains how to deploy the Alpaca MCP Server to Google Cloud Run.

## Prerequisites

1. **Google Cloud Account**: You need a GCP account with billing enabled
2. **gcloud CLI**: Install the Google Cloud SDK
   ```bash
   # macOS
   brew install google-cloud-sdk

   # Or download from: https://cloud.google.com/sdk/install
   ```
3. **Docker**: Install Docker Desktop for local builds
4. **Alpaca API Keys**: Get your API keys from [Alpaca Markets](https://app.alpaca.markets/dashboard/overview)

## Initial Setup

### 1. Authenticate with Google Cloud

```bash
# Login to Google Cloud
gcloud auth login

# Set your project ID
gcloud config set project YOUR_PROJECT_ID

# Configure Docker authentication
gcloud auth configure-docker us-central1-docker.pkg.dev
```

### 2. Enable Required APIs

```bash
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com
```

### 3. Create Secrets in Secret Manager

For development/paper trading:
```bash
echo -n 'your-paper-api-key' | gcloud secrets create ALPACA_API_KEY_DEV --data-file=-
echo -n 'your-paper-secret-key' | gcloud secrets create ALPACA_SECRET_KEY_DEV --data-file=-
```

For production/live trading:
```bash
echo -n 'your-live-api-key' | gcloud secrets create ALPACA_API_KEY --data-file=-
echo -n 'your-live-secret-key' | gcloud secrets create ALPACA_SECRET_KEY --data-file=-
```

### 4. Grant Cloud Run Access to Secrets

```bash
# Get the Cloud Run service account
PROJECT_NUMBER=$(gcloud projects describe $(gcloud config get-value project) --format='value(projectNumber)')
SERVICE_ACCOUNT="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Grant access to secrets
gcloud secrets add-iam-policy-binding ALPACA_API_KEY_DEV \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding ALPACA_SECRET_KEY_DEV \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

# For production secrets (if needed)
gcloud secrets add-iam-policy-binding ALPACA_API_KEY \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

gcloud secrets add-iam-policy-binding ALPACA_SECRET_KEY \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"
```

## Deployment Options

### Option 1: Using the Deployment Script (Recommended)

The easiest way to deploy is using the provided deployment script:

```bash
# Make the script executable
chmod +x deploy-to-gcp.sh

# Deploy to development (paper trading)
./deploy-to-gcp.sh development

# Deploy to production (live trading)
./deploy-to-gcp.sh production

# Deploy with specific project ID
./deploy-to-gcp.sh production my-gcp-project-id
```

The script will:
- Enable required GCP APIs
- Create an Artifact Registry repository
- Build and push the Docker image
- Deploy to Cloud Run with authentication required (secure by default)
- Configure secrets and environment variables

### Option 2: Using Cloud Build

Set up Cloud Build trigger for automatic deployments:

1. Connect your GitHub repository to Cloud Build:
   ```bash
   gcloud builds connect create github \
     --repo-uri=https://github.com/alpacahq/alpaca-mcp-server
   ```

2. Create a build trigger:
   ```bash
   gcloud builds triggers create github \
     --repo-name=alpaca-mcp-server \
     --branch-pattern=^main$ \
     --build-config=cloudbuild.yaml \
     --name=alpaca-mcp-deploy
   ```

3. Trigger a manual build:
   ```bash
   gcloud builds submit --config=cloudbuild.yaml
   ```

### Option 3: Manual Deployment

For complete control over the deployment:

```bash
# Build the Docker image
docker build -f Dockerfile.cloudrun -t us-central1-docker.pkg.dev/YOUR_PROJECT/alpaca-mcp/robt-alpaca-mcp:latest .

# Push to Artifact Registry
docker push us-central1-docker.pkg.dev/YOUR_PROJECT/alpaca-mcp/robt-alpaca-mcp:latest

# Deploy to Cloud Run
gcloud run deploy robt-alpaca-mcp \
  --image us-central1-docker.pkg.dev/YOUR_PROJECT/alpaca-mcp/robt-alpaca-mcp:latest \
  --region us-central1 \
  --platform managed \
  --no-allow-unauthenticated \
  --min-instances 0 \
  --max-instances 100 \
  --memory 512Mi \
  --cpu 1 \
  --timeout 300 \
  --port 8000 \
  --set-secrets=ALPACA_API_KEY=ALPACA_API_KEY:latest,ALPACA_SECRET_KEY=ALPACA_SECRET_KEY:latest \
  --set-env-vars=ALPACA_PAPER_TRADE=false
```

## Service Configuration

### Environment Variables

The service supports the following environment variables:

- `ALPACA_API_KEY`: Your Alpaca API key (required)
- `ALPACA_SECRET_KEY`: Your Alpaca secret key (required)
- `ALPACA_PAPER_TRADE`: Set to "true" for paper trading, "false" for live trading
- `DEBUG`: Enable debug logging ("true" or "false")
- `TRADE_API_URL`: Custom trading API URL (optional)
- `DATA_API_URL`: Custom data API URL (optional)

### Scaling Configuration

Default settings:
- **Min instances**: 0 (scales to zero when not in use)
- **Max instances**: 100 (adjustable based on needs)
- **Memory**: 512Mi
- **CPU**: 1
- **Timeout**: 300 seconds
- **Concurrency**: 1000 requests

Adjust these in the deployment command or Cloud Console based on your needs.

## Monitoring and Logs

### View Service Status

```bash
# Get service details
gcloud run services describe robt-alpaca-mcp --region us-central1

# List all services
gcloud run services list
```

### View Logs

```bash
# Stream live logs
gcloud logs tail --service=robt-alpaca-mcp

# View recent logs
gcloud logs read --service=robt-alpaca-mcp --limit=50

# View logs with filters
gcloud logs read "resource.type=cloud_run_revision AND resource.labels.service_name=robt-alpaca-mcp" --limit=100
```

### Metrics and Monitoring

1. Go to [Cloud Console](https://console.cloud.google.com)
2. Navigate to Cloud Run
3. Click on your service (robt-alpaca-mcp)
4. View metrics tab for:
   - Request count
   - Latency
   - Container instances
   - CPU and Memory utilization

## Authentication and Access

Since the service requires authentication, you'll need to provide credentials to access it.

### Granting Access to Users

```bash
# Grant access to a specific user
gcloud run services add-iam-policy-binding robt-alpaca-mcp \
  --region=us-central1 \
  --member="user:email@example.com" \
  --role="roles/run.invoker"

# Grant access to a service account
gcloud run services add-iam-policy-binding robt-alpaca-mcp \
  --region=us-central1 \
  --member="serviceAccount:service-account@project.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

### Testing the Authenticated Service

After deployment, you'll receive a URL like:
`https://robt-alpaca-mcp-91326830848.us-central1.run.app`

Test the service with authentication:

```bash
# Get an identity token
TOKEN=$(gcloud auth print-identity-token)

# Make authenticated request
curl -H "Authorization: Bearer $TOKEN" \
  https://robt-alpaca-mcp-91326830848.us-central1.run.app/health

# For programmatic access, use a service account key
gcloud iam service-accounts keys create key.json \
  --iam-account=SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com

# Use the service account to get a token
TOKEN=$(gcloud auth print-identity-token --impersonate-service-account=SERVICE_ACCOUNT@PROJECT.iam.gserviceaccount.com)
```

### Using with MCP Clients

For MCP clients that need to access the authenticated service:

1. Create a service account:
```bash
gcloud iam service-accounts create mcp-client \
  --display-name="MCP Client Service Account"
```

2. Grant it access:
```bash
gcloud run services add-iam-policy-binding robt-alpaca-mcp \
  --region=us-central1 \
  --member="serviceAccount:mcp-client@YOUR_PROJECT.iam.gserviceaccount.com" \
  --role="roles/run.invoker"
```

3. Configure your MCP client with the service account credentials

## Updating the Service

### Update Environment Variables

```bash
gcloud run services update robt-alpaca-mcp \
  --region us-central1 \
  --update-env-vars KEY=VALUE
```

### Update Secrets

```bash
# Create new secret version
echo -n 'new-api-key' | gcloud secrets versions add ALPACA_API_KEY --data-file=-

# The service will automatically use the latest version
```

### Redeploy with New Code

```bash
# Simply run the deployment script again
./deploy-to-gcp.sh production

# Or trigger Cloud Build
gcloud builds submit --config=cloudbuild.yaml
```

## Cost Optimization

Cloud Run charges based on:
- CPU and memory allocation time
- Request count
- Networking

Tips to minimize costs:
1. **Scale to zero**: Keep min-instances at 0
2. **Right-size resources**: Start with 512Mi memory and 1 CPU
3. **Use appropriate timeouts**: Don't set unnecessarily long timeouts
4. **Enable CPU throttling**: Only allocate CPU during request processing

## Security Best Practices

1. **Never hardcode secrets** in code or Dockerfiles
2. **Use Secret Manager** for all sensitive data
3. **Enable audit logging** for production deployments
4. **Restrict IAM permissions** to minimum required
5. **Use separate projects** for dev/staging/production
6. **Enable VPC Service Controls** for additional security
7. **Regularly rotate API keys** and update secrets

## Troubleshooting

### Common Issues

1. **Deployment fails with permission error**:
   ```bash
   # Grant Cloud Run Admin role
   gcloud projects add-iam-policy-binding YOUR_PROJECT \
     --member="user:your-email@example.com" \
     --role="roles/run.admin"
   ```

2. **Secret access denied**:
   ```bash
   # Verify secret exists
   gcloud secrets list

   # Check IAM permissions
   gcloud secrets get-iam-policy ALPACA_API_KEY
   ```

3. **Container fails to start**:
   ```bash
   # Check logs
   gcloud logs read --service=robt-alpaca-mcp --limit=100

   # Verify Docker image
   docker run -e ALPACA_API_KEY=test -e ALPACA_SECRET_KEY=test \
     us-central1-docker.pkg.dev/YOUR_PROJECT/alpaca-mcp/robt-alpaca-mcp:latest
   ```

4. **Service returns 500 errors**:
   - Check environment variables are set correctly
   - Verify Alpaca API keys are valid
   - Review application logs for specific errors

## Support

For issues or questions:
- GitHub Issues: https://github.com/alpacahq/alpaca-mcp-server/issues
- Alpaca Support: https://alpaca.markets/support