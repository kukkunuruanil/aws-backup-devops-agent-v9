#!/bin/bash
set -euo pipefail

# ════════════════════════════════════════════════════════════════════
# AWS Backup DevOps Agent v9 — Fully Automated Deployment
# Run from the DELEGATED ADMIN account.
# ════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STACK_NAME="BackupDevOpsAgent"
STACKSET_NAME="BackupEventForwarder"

echo "╔═══════════════════════════════════════════════════════════╗"
echo "║   AWS Backup DevOps Agent v9 - Automated Deployment      ║"
echo "╚═══════════════════════════════════════════════════════════╝"
echo ""

# ── Gather inputs ──
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
read -rp "Region for main stack [us-west-2]: " REGION
REGION="${REGION:-us-west-2}"
read -rp "Organization ID (o-xxxxxxxxxx): " ORG_ID
read -rp "Target OU ID (ou-xxxx-xxxxxxxx): " OU_ID
read -rp "Notification email: " EMAIL
read -rp "Deploy forwarding rules to all regions? (y/n) [y]: " ALL_REGIONS
ALL_REGIONS="${ALL_REGIONS:-y}"

if [[ "$ALL_REGIONS" == "y" ]]; then
  REGIONS=(us-east-1 us-east-2 us-west-1 us-west-2 ca-central-1 eu-west-1 eu-west-2 eu-west-3 eu-central-1 eu-north-1 ap-southeast-1 ap-southeast-2 ap-northeast-1 ap-northeast-2 ap-south-1 sa-east-1)
else
  REGIONS=("$REGION")
fi

echo ""
echo "  Account:  $ACCOUNT_ID"
echo "  Region:   $REGION"
echo "  Org:      $ORG_ID | OU: $OU_ID"
echo "  Regions:  ${#REGIONS[@]} for forwarding rules"
echo ""

# ════════════════════════════════════════════════════════════════════
# STEP 1: Create or reuse Agent Space
# ════════════════════════════════════════════════════════════════════
echo "── [1/7] Agent Space ──────────────────────────────────────"

SPACE_NAME="BackupInvestigations"
AGENT_SPACE_ID=$(aws devops-agent list-agent-spaces --region "$REGION" \
  --query "agentSpaces[?name=='$SPACE_NAME'].agentSpaceId | [0]" --output text 2>/dev/null || echo "None")

if [[ "$AGENT_SPACE_ID" == "None" || -z "$AGENT_SPACE_ID" ]]; then
  AGENT_SPACE_ID=$(aws devops-agent create-agent-space \
    --name "$SPACE_NAME" --region "$REGION" \
    --query 'agentSpace.agentSpaceId' --output text 2>/dev/null || echo "")
fi

if [[ -z "$AGENT_SPACE_ID" || "$AGENT_SPACE_ID" == "None" ]]; then
  echo "  ⚠  Could not auto-create. Enter Agent Space ID manually."
  read -rp "  Agent Space ID: " AGENT_SPACE_ID
fi
echo "  ✓ Agent Space: $AGENT_SPACE_ID"
AGENT_SPACE_ARN="arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/${AGENT_SPACE_ID}"

# ════════════════════════════════════════════════════════════════════
# STEP 2: Create primary IAM role for agent + associate account
# ════════════════════════════════════════════════════════════════════
echo "── [2/7] Primary IAM role + account association ───────────"

ROLE_NAME="DevOpsAgentBackupRole"
TRUST=$(cat <<EOF
{
  "Version":"2012-10-17",
  "Statement":[{
    "Effect":"Allow",
    "Principal":{"Service":"aidevops.amazonaws.com"},
    "Action":"sts:AssumeRole",
    "Condition":{
      "StringEquals":{"aws:SourceAccount":"$ACCOUNT_ID"},
      "ArnLike":{"aws:SourceArn":"$AGENT_SPACE_ARN"}
    }
  }]
}
EOF
)

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "$TRUST"
  echo "  ✓ Role exists, trust updated"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
  echo "  ✓ Role created"
fi
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy 2>/dev/null || true

# Associate account with agent space
aws devops-agent create-association \
  --agent-space-id "$AGENT_SPACE_ID" \
  --source-configuration "{\"aws\":{\"accountId\":\"$ACCOUNT_ID\",\"accountType\":\"MONITOR\",\"assumableRoleArn\":\"arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}\"}}" \
  --region "$REGION" &>/dev/null && echo "  ✓ Account associated" || echo "  ✓ Already associated"

# ════════════════════════════════════════════════════════════════════
# STEP 3: Webhook (manual step — cannot generate secret via CLI)
# ════════════════════════════════════════════════════════════════════
echo "── [3/7] Webhook ──────────────────────────────────────────"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ MANUAL: Create webhook in the DevOps Agent console       │"
echo "  │                                                          │"
echo "  │ Console → Agent Spaces → $SPACE_NAME → Webhooks         │"
echo "  │ → Create webhook → HMAC → Copy URL + Secret             │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
read -rp "  Webhook URL: " WEBHOOK_URL
read -rsp "  Webhook Secret: " WEBHOOK_SECRET
echo ""

if [[ -z "$WEBHOOK_URL" || -z "$WEBHOOK_SECRET" ]]; then
  echo "  ✗ Both required. Exiting."; exit 1
fi
echo "  ✓ Webhook configured"

# ════════════════════════════════════════════════════════════════════
# STEP 4: Deploy main CloudFormation stack
# ════════════════════════════════════════════════════════════════════
echo "── [4/7] Main stack ───────────────────────────────────────"

# Clean up stuck states
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NONE")
if [[ "$STACK_STATUS" == *ROLLBACK* || "$STACK_STATUS" == *FAILED* ]]; then
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
fi
# Force-delete orphaned secret
aws secretsmanager delete-secret --secret-id "devops-agent/backup-webhook" \
  --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
sleep 2

aws cloudformation deploy \
  --template-file "$SCRIPT_DIR/templates/main-stack.yaml" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides \
    WebhookUrl="$WEBHOOK_URL" \
    WebhookSecret="$WEBHOOK_SECRET" \
    OrganizationId="$ORG_ID" \
    NotificationEmail="$EMAIL" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region "$REGION" \
  --no-fail-on-empty-changeset
echo "  ✓ Main stack deployed"

# ════════════════════════════════════════════════════════════════════
# STEP 5: Deploy StackSet (forwarding + investigation role)
# ════════════════════════════════════════════════════════════════════
echo "── [5/7] StackSet → member accounts ───────────────────────"

if aws cloudformation describe-stack-set --stack-set-name "$STACKSET_NAME" \
  --call-as DELEGATED_ADMIN --region "$REGION" &>/dev/null; then
  echo "  → Updating existing StackSet..."
  aws cloudformation update-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$SCRIPT_DIR/templates/member-forwarder.yaml" \
    --parameters \
      "ParameterKey=DelegatedAdminAccountId,ParameterValue=$ACCOUNT_ID" \
      "ParameterKey=CentralRegion,ParameterValue=$REGION" \
      "ParameterKey=AgentSpaceArn,ParameterValue=$AGENT_SPACE_ARN" \
    --capabilities CAPABILITY_NAMED_IAM \
    --operation-preferences "FailureTolerancePercentage=100,MaxConcurrentPercentage=100" \
    --call-as DELEGATED_ADMIN --region "$REGION" 2>/dev/null \
    && echo "  ✓ StackSet updated" || echo "  ✓ No changes"
else
  echo "  → Creating StackSet..."
  aws cloudformation create-stack-set \
    --stack-set-name "$STACKSET_NAME" \
    --template-body "file://$SCRIPT_DIR/templates/member-forwarder.yaml" \
    --parameters \
      "ParameterKey=DelegatedAdminAccountId,ParameterValue=$ACCOUNT_ID" \
      "ParameterKey=CentralRegion,ParameterValue=$REGION" \
      "ParameterKey=AgentSpaceArn,ParameterValue=$AGENT_SPACE_ARN" \
    --permission-model SERVICE_MANAGED \
    --auto-deployment "Enabled=true,RetainStacksOnAccountRemoval=false" \
    --capabilities CAPABILITY_NAMED_IAM \
    --call-as DELEGATED_ADMIN --region "$REGION"
  echo "  ✓ StackSet created"
fi

# Deploy instances
echo "  → Deploying to OU $OU_ID across ${#REGIONS[@]} regions..."
aws cloudformation create-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --deployment-targets "OrganizationalUnitIds=$OU_ID" \
  --regions "${REGIONS[@]}" \
  --operation-preferences "FailureTolerancePercentage=100,MaxConcurrentPercentage=100" \
  --call-as DELEGATED_ADMIN --region "$REGION" &>/dev/null \
  && echo "  ✓ Instances deploying" \
  || echo "  ✓ Instances already exist"

# Wait briefly then check
sleep 10
echo "  → Instance status:"
aws cloudformation list-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --call-as DELEGATED_ADMIN --region "$REGION" \
  --query 'Summaries[].[Account,Region,StackInstanceStatus.DetailedStatus]' \
  --output table 2>/dev/null || echo "  (still deploying — check later)"

# ════════════════════════════════════════════════════════════════════
# STEP 6: Register secondary accounts for investigation
# ════════════════════════════════════════════════════════════════════
echo "── [6/7] Register secondary accounts with Agent Space ─────"

# Get all member accounts in the OU
MEMBER_ACCOUNTS=$(aws organizations list-accounts-for-parent --parent-id "$OU_ID" \
  --query "Accounts[?Id!='$ACCOUNT_ID'].Id" --output text 2>/dev/null || echo "")

if [[ -z "$MEMBER_ACCOUNTS" ]]; then
  echo "  ⚠  No member accounts found in OU, or not running from management/delegated-admin."
  echo "     You can manually register accounts later with:"
  echo "     aws devops-agent create-association --agent-space-id $AGENT_SPACE_ID \\"
  echo "       --source-configuration '{\"aws\":{\"accountId\":\"MEMBER_ID\",\"accountType\":\"SOURCE\",\"assumableRoleArn\":\"arn:aws:iam::MEMBER_ID:role/DevOpsAgentInvestigationRole\"}}' \\"
  echo "       --region $REGION"
else
  COUNT=0
  for MEMBER_ID in $MEMBER_ACCOUNTS; do
    aws devops-agent create-association \
      --agent-space-id "$AGENT_SPACE_ID" \
      --source-configuration "{\"aws\":{\"accountId\":\"$MEMBER_ID\",\"accountType\":\"SOURCE\",\"assumableRoleArn\":\"arn:aws:iam::${MEMBER_ID}:role/DevOpsAgentInvestigationRole\"}}" \
      --region "$REGION" &>/dev/null && ((COUNT++)) || true
  done
  echo "  ✓ Registered $COUNT member accounts as secondary sources"
fi

# ════════════════════════════════════════════════════════════════════
# STEP 7: Slack + test
# ════════════════════════════════════════════════════════════════════
echo "── [7/7] Final steps ──────────────────────────────────────"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │ MANUAL: Connect Slack                                    │"
echo "  │                                                          │"
echo "  │ Console → Agent Spaces → $SPACE_NAME → Capabilities     │"
echo "  │ → Add Slack → Complete OAuth → /invite @AWS DevOps Agent │"
echo "  └─────────────────────────────────────────────────────────┘"
echo ""
echo "  → Sending test event..."
aws events put-events --region "$REGION" --entries "[{
  \"Source\":\"aws.backup\",
  \"DetailType\":\"Copy Job State Change\",
  \"Detail\":\"{\\\"state\\\":\\\"FAILED\\\",\\\"copyJobId\\\":\\\"DEPLOY-TEST-$(date +%s)\\\",\\\"statusMessage\\\":\\\"Deployment validation\\\",\\\"accountId\\\":\\\"$ACCOUNT_ID\\\",\\\"resourceArn\\\":\\\"arn:aws:ec2:$REGION:${ACCOUNT_ID}:volume/vol-test\\\",\\\"backupVaultName\\\":\\\"Default\\\"}\"
}]" >/dev/null && echo "  ✓ Test event sent"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  ✓ DEPLOYMENT COMPLETE                                    ║"
echo "╠═══════════════════════════════════════════════════════════╣"
echo "║  Agent Space: $AGENT_SPACE_ID"
echo "║  Stack:       $STACK_NAME ($REGION)"
echo "║  StackSet:    $STACKSET_NAME (auto-deploys to new accts) "
echo "║  Email:       $EMAIL (confirm SNS subscription!)         "
echo "║                                                           ║"
echo "║  TODO:                                                    ║"
echo "║  1. Confirm SNS email subscription (check inbox)          ║"
echo "║  2. Connect Slack in DevOps Agent console                 ║"
echo "║  3. /invite @AWS DevOps Agent in your channel             ║"
echo "╚═══════════════════════════════════════════════════════════╝"
