# Implementation Guide: AWS Backup DevOps Agent v9

**Run everything from your delegated administrator account.**

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| AWS Organizations with ≥1 member account | `aws organizations describe-organization` |
| Delegated admin for AWS Backup | `aws organizations list-delegated-administrators --service-principal backup.amazonaws.com` |
| Delegated admin for CloudFormation StackSets | See "One-time setup" below |
| AWS DevOps Agent access | Console shows DevOps Agent service |
| AWS CLI v2 | `aws --version` |
| Slack workspace (admin access) | You can install apps |

### One-time setup (run from management account)

```bash
aws organizations register-delegated-administrator \
  --account-id YOUR_DELEGATED_ADMIN_ID \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com
```

---

## Quick start (automated)

```bash
cd aws-backup-devops-agent-v9
./deploy.sh
```

The script handles all 7 steps below. It pauses only for webhook creation (must copy from console) and reminds you to connect Slack afterward.

---

## Step-by-step breakdown

### Step 1 — Create Agent Space

```bash
REGION=us-west-2

aws devops-agent create-agent-space \
  --name "BackupInvestigations" \
  --region $REGION
```

Note the `agentSpaceId` from the output.

---

### Step 2 — Create primary IAM role + associate account

Create a role that the DevOps Agent service can assume:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AGENT_SPACE_ID=<from step 1>
AGENT_SPACE_ARN="arn:aws:aidevops:${REGION}:${ACCOUNT_ID}:agentspace/${AGENT_SPACE_ID}"

cat > /tmp/trust.json << EOF
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

aws iam create-role \
  --role-name DevOpsAgentBackupRole \
  --assume-role-policy-document file:///tmp/trust.json

aws iam attach-role-policy \
  --role-name DevOpsAgentBackupRole \
  --policy-arn arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy
```

Associate the account with the agent space:

```bash
aws devops-agent create-association \
  --agent-space-id $AGENT_SPACE_ID \
  --source-configuration "{\"aws\":{\"accountId\":\"$ACCOUNT_ID\",\"accountType\":\"MONITOR\",\"assumableRoleArn\":\"arn:aws:iam::${ACCOUNT_ID}:role/DevOpsAgentBackupRole\"}}" \
  --region $REGION
```

---

### Step 3 — Create webhook (console required)

1. Open: **DevOps Agent console → Agent Spaces → BackupInvestigations → Webhooks**
2. Click **Create webhook** → select **HMAC**
3. Copy the **URL** and **Secret** (secret shown only once)

> Why manual? The webhook secret is generated server-side and cannot be retrieved via CLI after creation.

---

### Step 4 — Deploy main CloudFormation stack

```bash
aws cloudformation deploy \
  --template-file templates/main-stack.yaml \
  --stack-name BackupDevOpsAgent \
  --parameter-overrides \
    WebhookUrl="<webhook URL from step 3>" \
    WebhookSecret="<webhook secret from step 3>" \
    OrganizationId="o-xxxxxxxxxx" \
    NotificationEmail="you@example.com" \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION
```

This creates:
- EventBus policy (accepts events from your org)
- EventBridge rule (backup failures → Lambda)
- EventBridge rule (investigation complete → emailer Lambda)
- `BackupFailureBridge` Lambda (signs + posts to webhook)
- `BackupRCAEmailer` Lambda (formats + publishes to SNS)
- SNS topic + email subscription
- Secrets Manager secret (webhook creds)

**After deploy: confirm the SNS subscription email in your inbox.**

---

### Step 5 — Deploy StackSet to member accounts

```bash
OU_ID=ou-xxxx-xxxxxxxx

aws cloudformation create-stack-set \
  --stack-set-name BackupEventForwarder \
  --template-body file://templates/member-forwarder.yaml \
  --parameters \
    ParameterKey=DelegatedAdminAccountId,ParameterValue=$ACCOUNT_ID \
    ParameterKey=CentralRegion,ParameterValue=$REGION \
    ParameterKey=AgentSpaceArn,ParameterValue=$AGENT_SPACE_ARN \
  --permission-model SERVICE_MANAGED \
  --auto-deployment "Enabled=true,RetainStacksOnAccountRemoval=false" \
  --capabilities CAPABILITY_NAMED_IAM \
  --call-as DELEGATED_ADMIN --region $REGION

aws cloudformation create-stack-instances \
  --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions us-east-1 us-west-2 eu-west-1 \
  --operation-preferences "FailureTolerancePercentage=100,MaxConcurrentPercentage=100" \
  --call-as DELEGATED_ADMIN --region $REGION
```

This deploys to each member account:
- `ForwardBackupFailures-ToCentral` EventBridge rule (every region you specify)
- `BackupEventForwardingRole` IAM role (once per account — allows cross-account event delivery)
- `DevOpsAgentInvestigationRole` IAM role (once per account — trusts `aidevops.amazonaws.com`, uses `AIDevOpsAgentAccessPolicy`)

Verify:

```bash
aws cloudformation list-stack-instances \
  --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region $REGION \
  --query 'Summaries[].[Account,Region,StackInstanceStatus.DetailedStatus]' \
  --output table
```

---

### Step 6 — Register member accounts for investigation

The StackSet deployed the investigation role, but you must also **tell the agent space about each account**:

```bash
# Get member accounts in the OU
MEMBERS=$(aws organizations list-accounts-for-parent --parent-id $OU_ID \
  --query "Accounts[?Id!='$ACCOUNT_ID'].Id" --output text)

for MEMBER_ID in $MEMBERS; do
  aws devops-agent create-association \
    --agent-space-id $AGENT_SPACE_ID \
    --source-configuration "{\"aws\":{\"accountId\":\"$MEMBER_ID\",\"accountType\":\"SOURCE\",\"assumableRoleArn\":\"arn:aws:iam::${MEMBER_ID}:role/DevOpsAgentInvestigationRole\"}}" \
    --region $REGION
  echo "  ✓ $MEMBER_ID registered"
done
```

> **Important:** New accounts joining the OU get the IAM role automatically (via StackSet auto-deployment), but you must re-run this loop to register them with the agent space. Consider a scheduled Lambda or EventBridge rule on `CreateAccountResult` to automate this.

---

### Step 7 — Connect Slack + validate

1. **Console → Agent Spaces → BackupInvestigations → Capabilities → Add Slack**
2. Complete OAuth authorization
3. In Slack: `/invite @AWS DevOps Agent`

Test end-to-end:

```bash
aws events put-events --region $REGION --entries '[{
  "Source":"aws.backup",
  "DetailType":"Copy Job State Change",
  "Detail":"{\"state\":\"FAILED\",\"copyJobId\":\"TEST-001\",\"statusMessage\":\"KMS key disabled\",\"accountId\":\"111122223333\",\"resourceArn\":\"arn:aws:ec2:us-west-2:111122223333:volume/vol-test\",\"backupVaultName\":\"Default\"}"
}]'
```

Expected within 3-5 minutes:
- Investigation appears in Slack
- RCA email lands in your inbox

---

## What can't be automated (and why)

| Step | Why manual | Workaround |
|---|---|---|
| Webhook secret | Generated server-side, shown once, no CLI retrieval | None — copy from console |
| Slack OAuth | Browser-based OAuth flow | None — click through once |
| SNS email confirmation | AWS requires human click | Check inbox after deploy |

Everything else is CLI/CloudFormation.

---

## Cleanup

```bash
# Remove member forwarding stacks
aws cloudformation delete-stack-instances \
  --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions us-east-1 us-west-2 eu-west-1 \
  --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region $REGION

# Wait, then delete StackSet
aws cloudformation delete-stack-set \
  --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region $REGION

# Delete main stack
aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION

# Optional: delete agent space
aws devops-agent delete-agent-space --agent-space-id $AGENT_SPACE_ID --region $REGION
```

> Note: `DevOpsAgentInvestigationRole` has `DeletionPolicy: Retain` — delete manually if no longer needed.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| StackSet fails for delegated-admin account | Expected — template skips it via `IsNotAdmin` condition |
| `list-accounts-for-parent` empty | Must run from management account or have Organizations read access |
| Lambda 403 from webhook | Secret rotated? Update in Secrets Manager |
| No Slack message | Agent not invited to channel — run `/invite @AWS DevOps Agent` |
| No email | SNS subscription not confirmed — check spam folder |
| Agent can't investigate member account | Account not registered (step 6) or StackSet not yet deployed role |
| 3 concurrent investigations limit | Request quota increase via Service Quotas console |
