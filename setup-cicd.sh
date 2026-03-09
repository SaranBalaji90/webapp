#!/bin/bash
set -euo pipefail

#############################################
# Configuration
#############################################
AWS_ACCOUNT_ID="908176817140"
AWS_REGION="us-west-2"
ECR_REPO_URI="908176817140.dkr.ecr.us-west-2.amazonaws.com/myapp"
ECR_REPO_NAME="myapp"
EKS_CLUSTER_NAME="reinvent-test"
APP_NAME="webapp"
CODEBUILD_PROJECT="webapp-build"
K8S_NAMESPACE="webapp"
K8S_DEPLOYMENT="webapp"

# GitHub source — UPDATE THESE
GITHUB_REPO="https://github.com/SaranBalaji90/webapp.git"
GITHUB_BRANCH="main"
# If private repo, create a CodeBuild source credential first (see Step 2 note)

echo "Account:  $AWS_ACCOUNT_ID"
echo "Region:   $AWS_REGION"
echo "ECR:      $ECR_REPO_URI"
echo "EKS:      $EKS_CLUSTER_NAME"
echo ""

#############################################
# Step 1: Create IAM Role for CodeBuild
#############################################
echo ">>> Step 1: Creating CodeBuild service role..."

CODEBUILD_ROLE_NAME="codebuild-${APP_NAME}-role"

cat > /tmp/codebuild-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --assume-role-policy-document file:///tmp/codebuild-trust-policy.json \
  --description "CodeBuild role for $APP_NAME" \
  2>/dev/null || echo "  Role already exists, continuing..."

# Inline policy: ECR push, CloudWatch Logs, EKS describe, S3 cache
cat > /tmp/codebuild-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Sid": "ECRPush",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPO_NAME}"
    },
    {
      "Sid": "EKSDescribe",
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:${AWS_REGION}:${AWS_ACCOUNT_ID}:cluster/${EKS_CLUSTER_NAME}"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:${AWS_REGION}:${AWS_ACCOUNT_ID}:log-group:/aws/codebuild/*"
    },
    {
      "Sid": "STS",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$CODEBUILD_ROLE_NAME" \
  --policy-name "codebuild-${APP_NAME}-policy" \
  --policy-document file:///tmp/codebuild-policy.json

echo "  Waiting for IAM role propagation..."
sleep 10

CODEBUILD_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}"
echo "  Role ARN: $CODEBUILD_ROLE_ARN"

#############################################
# Step 2: Create CodeBuild Project
#############################################
echo ""
echo ">>> Step 2: Creating CodeBuild project..."

# NOTE: If your GitHub repo is private, first run:
# aws codebuild import-source-credentials \
#   --server-type GITHUB \
#   --auth-type PERSONAL_ACCESS_TOKEN \
#   --token YOUR_GITHUB_PAT \
#   --region "$AWS_REGION"

aws codebuild create-project \
  --name "$CODEBUILD_PROJECT" \
  --description "Build and push webapp Docker image to ECR" \
  --source '{
    "type": "GITHUB",
    "location": "'"$GITHUB_REPO"'",
    "buildspec": "buildspec.yml",
    "gitCloneDepth": 1
  }' \
  --artifacts '{"type": "NO_ARTIFACTS"}' \
  --environment '{
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/amazonlinux2-x86_64-standard:5.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      {"name": "AWS_ACCOUNT_ID", "value": "'"$AWS_ACCOUNT_ID"'", "type": "PLAINTEXT"},
      {"name": "AWS_DEFAULT_REGION", "value": "'"$AWS_REGION"'", "type": "PLAINTEXT"},
      {"name": "ECR_REPO_URI", "value": "'"$ECR_REPO_URI"'", "type": "PLAINTEXT"},
      {"name": "EKS_CLUSTER_NAME", "value": "'"$EKS_CLUSTER_NAME"'", "type": "PLAINTEXT"},
      {"name": "K8S_NAMESPACE", "value": "'"$K8S_NAMESPACE"'", "type": "PLAINTEXT"},
      {"name": "K8S_DEPLOYMENT", "value": "'"$K8S_DEPLOYMENT"'", "type": "PLAINTEXT"}
    ]
  }' \
  --service-role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}" \
  --source-version "$GITHUB_BRANCH" \
  --region "$AWS_REGION"

echo "  CodeBuild project created: $CODEBUILD_PROJECT"

# Optional: Set up webhook so builds trigger on push
echo ""
echo ">>> Step 2b: Creating webhook for auto-trigger on push..."
aws codebuild create-webhook \
  --project-name "$CODEBUILD_PROJECT" \
  --filter-groups '[[{"type":"EVENT","pattern":"PUSH"},{"type":"HEAD_REF","pattern":"^refs/heads/'"$GITHUB_BRANCH"'$"}]]' \
  --region "$AWS_REGION" \
  2>/dev/null || echo "  Webhook may already exist or GitHub connection needed, continuing..."

#############################################
# Step 3: Grant CodeBuild access to EKS
#############################################
echo ""
echo ">>> Step 3: Granting CodeBuild role access to EKS cluster..."
echo ""
echo "  You need to add the CodeBuild role to your EKS cluster's aws-auth ConfigMap."
echo "  Run this manually if you haven't already:"
echo ""
echo "  kubectl edit configmap aws-auth -n kube-system"
echo ""
echo "  Add this under 'mapRoles':"
echo "  - rolearn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME}"
echo "    username: codebuild"
echo "    groups:"
echo "      - system:masters"
echo ""
echo "  OR use eksctl:"
echo "  eksctl create iamidentitymapping \\"
echo "    --cluster $EKS_CLUSTER_NAME \\"
echo "    --region $AWS_REGION \\"
echo "    --arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CODEBUILD_ROLE_NAME} \\"
echo "    --username codebuild \\"
echo "    --group system:masters"
echo ""

#############################################
# Step 4: Create K8s namespace and deployment
#############################################
echo ">>> Step 4: Creating K8s resources for webapp..."

# Create namespace
kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create deployment
cat <<DEPLOY | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $K8S_DEPLOYMENT
  namespace: $K8S_NAMESPACE
  labels:
    app: $K8S_DEPLOYMENT
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app: $K8S_DEPLOYMENT
  template:
    metadata:
      labels:
        app: $K8S_DEPLOYMENT
    spec:
      containers:
        - name: $K8S_DEPLOYMENT
          image: ${ECR_REPO_URI}:latest
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 30
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
DEPLOY

# Create service
cat <<SVC | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: $K8S_DEPLOYMENT
  namespace: $K8S_NAMESPACE
  labels:
    app: $K8S_DEPLOYMENT
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
  selector:
    app: $K8S_DEPLOYMENT
SVC

echo "  K8s deployment and service created."

#############################################
# Step 5: Trigger first build
#############################################
echo ""
echo ">>> Step 5: Triggering first CodeBuild run..."

BUILD_ID=$(aws codebuild start-build \
  --project-name "$CODEBUILD_PROJECT" \
  --region "$AWS_REGION" \
  --query 'build.id' \
  --output text)

echo "  Build started: $BUILD_ID"
echo "  Monitor at: https://${AWS_REGION}.console.aws.amazon.com/codesuite/codebuild/projects/${CODEBUILD_PROJECT}/build/${BUILD_ID}"

#############################################
# Summary
#############################################
echo ""
echo "============================================"
echo "  CI/CD Pipeline Setup Complete"
echo "============================================"
echo ""
echo "  ECR Repo:       $ECR_REPO_URI"
echo "  CodeBuild:      $CODEBUILD_PROJECT"
echo "  EKS Cluster:    $EKS_CLUSTER_NAME"
echo "  K8s Namespace:  $K8S_NAMESPACE"
echo "  K8s Deployment: $K8S_DEPLOYMENT"
echo ""
echo "  Flow: GitHub push -> CodeBuild -> Docker build -> ECR push -> kubectl deploy to EKS"
echo ""
echo "  IMPORTANT: Make sure to complete Step 3 (EKS aws-auth) if not done already."
echo "  Get your app URL with: kubectl get svc $K8S_DEPLOYMENT -n $K8S_NAMESPACE"
echo ""
