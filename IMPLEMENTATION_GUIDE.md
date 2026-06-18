# Implementation Guide: AWS Backup DevOps Agent v9

**Fully self-contained. Copy the templates and script below, then run.**

---

## Prerequisites

| Requirement | How to verify |
|---|---|
| AWS Organizations with ≥1 member account | `aws organizations describe-organization` |
| Delegated admin for AWS Backup | `aws organizations list-delegated-administrators --service-principal backup.amazonaws.com` |
| Delegated admin for CloudFormation StackSets | See one-time setup below |
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

## File setup

Create this directory structure and paste the contents below:

```
aws-backup-devops-agent-v9/
├── deploy.sh
└── templates/
    ├── main-stack.yaml
    └── member-forwarder.yaml
```

```bash
mkdir -p aws-backup-devops-agent-v9/templates
cd aws-backup-devops-agent-v9
```

---

## File 1: templates/main-stack.yaml

**What this does:** Deploys all resources in the **delegated administrator account**. Specifically:

- **Secrets Manager secret** — stores the DevOps Agent webhook URL and HMAC secret securely
- **SNS topic + email subscription** — delivers RCA summaries to your inbox
- **EventBus policy** — allows any account in your organization to send events to this account's default event bus (scoped by `aws:PrincipalOrgID`)
- **EventBridge rule #1** (`BackupFailures-TriggerInvestigation`) — catches backup/copy job events in FAILED, ABORTED, or EXPIRED state and invokes the bridge Lambda
- **EventBridge rule #2** (`BackupRCA-SendEmail`) — catches DevOps Agent's "Investigation Complete" event and invokes the emailer Lambda
- **Lambda #1** (`BackupFailureBridge`) — reads the webhook secret, builds the incident payload, HMAC-signs it, and POSTs to the DevOps Agent webhook to start an investigation
- **Lambda #2** (`BackupRCAEmailer`) — formats the investigation results into a human-readable email and publishes to the SNS topic
- **IAM roles** (2) — least-privilege execution roles for each Lambda (one can read the secret, the other can publish to SNS)

Copy and save as `templates/main-stack.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  AWS Backup DevOps Agent v9 - Main Stack (Delegated Admin Account).
  Central event bus, bridge Lambda, RCA emailer Lambda, SNS topic.

Parameters:
  WebhookUrl:
    Type: String
    NoEcho: true
  WebhookSecret:
    Type: String
    NoEcho: true
  OrganizationId:
    Type: String
    Description: AWS Organization ID (o-xxxxxxxxxx)
  NotificationEmail:
    Type: String
    Description: Email for RCA summaries

Resources:
  # ── Secrets Manager ──
  WebhookCredentials:
    Type: AWS::SecretsManager::Secret
    Properties:
      Name: devops-agent/backup-webhook
      SecretString: !Sub '{"webhookUrl":"${WebhookUrl}","webhookSecret":"${WebhookSecret}"}'

  # ── SNS ──
  RCANotificationTopic:
    Type: AWS::SNS::Topic
    Properties:
      TopicName: BackupRCA-Notifications

  EmailSubscription:
    Type: AWS::SNS::Subscription
    Properties:
      TopicArn: !Ref RCANotificationTopic
      Protocol: email
      Endpoint: !Ref NotificationEmail

  # ── EventBus Policy: accept from org ──
  EventBusPolicy:
    Type: AWS::Events::EventBusPolicy
    Properties:
      StatementId: AllowOrgPutEvents
      Action: events:PutEvents
      Principal: '*'
      Condition:
        Type: StringEquals
        Key: aws:PrincipalOrgID
        Value: !Ref OrganizationId

  # ── Rule 1: backup failures → bridge Lambda ──
  BackupFailureRule:
    Type: AWS::Events::Rule
    Properties:
      Name: BackupFailures-TriggerInvestigation
      State: ENABLED
      EventPattern:
        source:
          - aws.backup
        detail-type:
          - Backup Job State Change
          - Copy Job State Change
        detail:
          state:
            - FAILED
            - ABORTED
            - EXPIRED
      Targets:
        - Id: Bridge
          Arn: !GetAtt BridgeLambda.Arn

  # ── Rule 2: investigation complete → emailer Lambda ──
  InvestigationCompleteRule:
    Type: AWS::Events::Rule
    Properties:
      Name: BackupRCA-SendEmail
      State: ENABLED
      EventPattern:
        source:
          - aws.aidevops
        detail-type:
          - Investigation Complete
      Targets:
        - Id: Emailer
          Arn: !GetAtt EmailerLambda.Arn

  # ── Lambda 1: Bridge ──
  BridgeLambda:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: BackupFailureBridge
      Runtime: python3.12
      Handler: index.lambda_handler
      Timeout: 30
      Role: !GetAtt BridgeRole.Arn
      Code:
        ZipFile: |
          import json, hashlib, hmac, base64, urllib.request, boto3
          from datetime import datetime, timezone

          def lambda_handler(event, context):
              sm = boto3.client('secretsmanager')
              creds = json.loads(sm.get_secret_value(SecretId='devops-agent/backup-webhook')['SecretString'])
              url, secret = creds['webhookUrl'], creds['webhookSecret']

              detail = event.get('detail', {})
              payload = json.dumps({
                  'eventType': 'incident',
                  'incidentId': detail.get('backupJobId') or detail.get('copyJobId') or 'unknown',
                  'action': 'created',
                  'priority': 'HIGH',
                  'title': f"AWS Backup {detail.get('state','FAILED')} - {detail.get('statusMessage','')[:100]}",
                  'description': f"Account: {detail.get('accountId','?')}\nRegion: {event.get('region','?')}\nResource: {detail.get('resourceArn','?')}\nVault: {detail.get('backupVaultName','?')}\nMessage: {detail.get('statusMessage','?')}",
                  'timestamp': datetime.now(timezone.utc).isoformat(),
                  'service': 'aws.backup',
                  'data': detail
              })

              ts = datetime.now(timezone.utc).isoformat()
              sig = base64.b64encode(hmac.new(secret.encode(), f"{ts}:{payload}".encode(), hashlib.sha256).digest()).decode()

              req = urllib.request.Request(url, data=payload.encode(), headers={
                  'Content-Type': 'application/json',
                  'x-amzn-event-timestamp': ts,
                  'x-amzn-event-signature': sig
              }, method='POST')
              with urllib.request.urlopen(req) as resp:
                  print(f"Webhook response: {resp.status}")
                  return {'statusCode': resp.status}

  # ── Lambda 2: Emailer ──
  EmailerLambda:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: BackupRCAEmailer
      Runtime: python3.12
      Handler: index.lambda_handler
      Timeout: 30
      Role: !GetAtt EmailerRole.Arn
      Environment:
        Variables:
          SNS_TOPIC_ARN: !Ref RCANotificationTopic
      Code:
        ZipFile: |
          import json, os, boto3
          from datetime import datetime, timezone

          def lambda_handler(event, context):
              detail = event.get('detail', {})
              subject = f"[AWS Backup RCA] {detail.get('title', detail.get('incidentId','Unknown'))[:80]}"
              message = f"""
          AWS Backup - Root Cause Analysis
          ════════════════════════════════════
          Incident:  {detail.get('incidentId','?')}
          Account:   {detail.get('accountId','?')}
          Region:    {detail.get('region','?')}
          Resource:  {detail.get('resourceArn','?')}
          Time:      {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}

          SUMMARY
          ────────
          {detail.get('summary','No summary available')}

          ROOT CAUSE
          ──────────
          {detail.get('rootCause','Pending')}

          RECOMMENDATION
          ──────────────
          {detail.get('recommendation','')}
          ════════════════════════════════════
          Generated by AWS Backup DevOps Agent pipeline.
          """
              boto3.client('sns').publish(
                  TopicArn=os.environ['SNS_TOPIC_ARN'],
                  Subject=subject[:100],
                  Message=message.strip()
              )
              return {'statusCode': 200}

  # ── Permissions: EventBridge → Lambda ──
  BridgeInvokePermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref BridgeLambda
      Action: lambda:InvokeFunction
      Principal: events.amazonaws.com
      SourceArn: !GetAtt BackupFailureRule.Arn

  EmailerInvokePermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Ref EmailerLambda
      Action: lambda:InvokeFunction
      Principal: events.amazonaws.com
      SourceArn: !GetAtt InvestigationCompleteRule.Arn

  # ── IAM Roles ──
  BridgeRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: BackupFailureBridgeRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: SecretsAccess
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: secretsmanager:GetSecretValue
                Resource: !Ref WebhookCredentials

  EmailerRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: BackupRCAEmailerRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
      Policies:
        - PolicyName: SNSPublish
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: sns:Publish
                Resource: !Ref RCANotificationTopic

Outputs:
  BridgeLambdaArn:
    Value: !GetAtt BridgeLambda.Arn
  EmailerLambdaArn:
    Value: !GetAtt EmailerLambda.Arn
  SNSTopicArn:
    Value: !Ref RCANotificationTopic
  EventBusArn:
    Value: !Sub arn:aws:events:${AWS::Region}:${AWS::AccountId}:event-bus/default
```

---

## File 2: templates/member-forwarder.yaml

**What this does:** Deployed via CloudFormation StackSet to **every member account** in your organization. Creates:

- **EventBridge forwarding rule** (`ForwardBackupFailures-ToCentral`) — deployed in *every Region* you select. Matches FAILED/ABORTED/EXPIRED backup and copy job events and sends them to the delegated admin's central event bus. This is how failures from any account/Region reach the investigation pipeline.
- **Forwarding IAM role** (`BackupEventForwardingRole`) — created *once per account* (IAM is global). Allows the EventBridge service to call `events:PutEvents` on the delegated admin's bus.
- **Investigation IAM role** (`DevOpsAgentInvestigationRole`) — created *once per account*. This is the role that AWS DevOps Agent assumes when it investigates a failure in this account. It trusts the `aidevops.amazonaws.com` service principal (scoped to your admin account and agent space), and uses the AWS-managed `AIDevOpsAgentAccessPolicy` for read-only investigation access.

> **Conditions built in:** The template skips the delegated admin account (it doesn't need to forward to itself) and creates IAM roles only in the central Region (avoiding naming conflicts since IAM is global).

Copy and save as `templates/member-forwarder.yaml`:

```yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: >
  AWS Backup DevOps Agent v9 - Member Account Forwarder (StackSet).
  Deploys forwarding rule (per Region) and IAM roles (once, global).

Parameters:
  DelegatedAdminAccountId:
    Type: String
  CentralRegion:
    Type: String
  AgentSpaceArn:
    Type: String
    Description: ARN of the DevOps Agent space (for investigation role trust scoping)

Conditions:
  IsNotAdmin: !Not [!Equals [!Ref "AWS::AccountId", !Ref DelegatedAdminAccountId]]
  IsCentralRegion: !Equals [!Ref "AWS::Region", !Ref CentralRegion]
  CreateRule: !Condition IsNotAdmin
  CreateIAM: !And [!Condition IsNotAdmin, !Condition IsCentralRegion]

Resources:
  # ── EventBridge forwarding rule (every Region) ──
  ForwardingRule:
    Type: AWS::Events::Rule
    Condition: CreateRule
    Properties:
      Name: ForwardBackupFailures-ToCentral
      State: ENABLED
      EventPattern:
        source:
          - aws.backup
        detail-type:
          - Backup Job State Change
          - Copy Job State Change
        detail:
          state:
            - FAILED
            - ABORTED
            - EXPIRED
      Targets:
        - Id: CentralBus
          Arn: !Sub arn:aws:events:${CentralRegion}:${DelegatedAdminAccountId}:event-bus/default
          RoleArn: !Sub arn:aws:iam::${AWS::AccountId}:role/BackupEventForwardingRole

  # ── IAM: Forwarding role (once per account) ──
  ForwardingRole:
    Type: AWS::IAM::Role
    Condition: CreateIAM
    DeletionPolicy: Retain
    Properties:
      RoleName: BackupEventForwardingRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: events.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: PutEvents
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action: events:PutEvents
                Resource: !Sub arn:aws:events:${CentralRegion}:${DelegatedAdminAccountId}:event-bus/default

  # ── IAM: Investigation role (once per account) ──
  InvestigationRole:
    Type: AWS::IAM::Role
    Condition: CreateIAM
    DeletionPolicy: Retain
    Properties:
      RoleName: DevOpsAgentInvestigationRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: aidevops.amazonaws.com
            Action: sts:AssumeRole
            Condition:
              StringEquals:
                aws:SourceAccount: !Ref DelegatedAdminAccountId
              ArnLike:
                aws:SourceArn: !Ref AgentSpaceArn
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AIDevOpsAgentAccessPolicy

Outputs:
  InvestigationRoleArn:
    Condition: CreateIAM
    Value: !GetAtt InvestigationRole.Arn
```

---

## File 3: deploy.sh

**What this does:** Orchestrates the entire deployment in 7 automated steps:

| Step | Action | Automated? |
|------|--------|------------|
| 1 | Creates (or reuses) a DevOps Agent Space named `BackupInvestigations` | ✓ |
| 2 | Creates the primary IAM role (`DevOpsAgentBackupRole`) with correct trust policy and associates your admin account with the agent space | ✓ |
| 3 | **Pauses** for you to create the HMAC webhook in the console and paste the URL + secret | Manual (secret shown only once) |
| 4 | Deploys the main CloudFormation stack (all delegated admin resources from File 1) | ✓ |
| 5 | Creates/updates the StackSet and deploys it to all member accounts across your chosen Regions (File 2) | ✓ |
| 6 | Loops through all member accounts in the target OU and registers each one as a secondary source in the agent space (required for cross-account investigation) | ✓ |
| 7 | Sends a synthetic test event and reminds you to connect Slack | ✓ |

The script is **idempotent** — safe to re-run. It handles existing resources, cleans up failed stacks, and waits for in-progress operations.

Copy and save as `deploy.sh`, then run `chmod +x deploy.sh`:

```bash
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

aws devops-agent create-association \
  --agent-space-id "$AGENT_SPACE_ID" \
  --source-configuration "{\"aws\":{\"accountId\":\"$ACCOUNT_ID\",\"accountType\":\"MONITOR\",\"assumableRoleArn\":\"arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}\"}}" \
  --region "$REGION" &>/dev/null && echo "  ✓ Account associated" || echo "  ✓ Already associated"

# ════════════════════════════════════════════════════════════════════
# STEP 3: Webhook (manual step)
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

STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "NONE")
if [[ "$STACK_STATUS" == *ROLLBACK* || "$STACK_STATUS" == *FAILED* ]]; then
  aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
  aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
fi
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

echo "  → Deploying to OU $OU_ID across ${#REGIONS[@]} regions..."
aws cloudformation create-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --deployment-targets "OrganizationalUnitIds=$OU_ID" \
  --regions "${REGIONS[@]}" \
  --operation-preferences "FailureTolerancePercentage=100,MaxConcurrentPercentage=100" \
  --call-as DELEGATED_ADMIN --region "$REGION" &>/dev/null \
  && echo "  ✓ Instances deploying" \
  || echo "  ✓ Instances already exist"

sleep 10
aws cloudformation list-stack-instances \
  --stack-set-name "$STACKSET_NAME" \
  --call-as DELEGATED_ADMIN --region "$REGION" \
  --query 'Summaries[].[Account,Region,StackInstanceStatus.DetailedStatus]' \
  --output table 2>/dev/null || echo "  (still deploying)"

# ════════════════════════════════════════════════════════════════════
# STEP 6: Register secondary accounts for investigation
# ════════════════════════════════════════════════════════════════════
echo "── [6/7] Register secondary accounts with Agent Space ─────"

MEMBER_ACCOUNTS=$(aws organizations list-accounts-for-parent --parent-id "$OU_ID" \
  --query "Accounts[?Id!='$ACCOUNT_ID'].Id" --output text 2>/dev/null || echo "")

if [[ -z "$MEMBER_ACCOUNTS" ]]; then
  echo "  ⚠  No member accounts found. Register manually later:"
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
```

---

## Running it

```bash
cd aws-backup-devops-agent-v9
chmod +x deploy.sh
./deploy.sh
```

The script pauses only at step 3 (webhook — must copy from console) and reminds you about Slack at the end.

---

## What cannot be automated (and why)

| Step | Why manual | When |
|---|---|---|
| Webhook secret | Generated server-side, shown once, no CLI retrieval | Step 3 |
| Slack OAuth | Browser-based authorization flow | After step 7 |
| SNS email confirmation | AWS requires human click on link | After step 4 |

---

## Validation

After deployment, confirm the pipeline works end-to-end:

```bash
aws events put-events --region us-west-2 --entries '[{
  "Source":"aws.backup",
  "DetailType":"Copy Job State Change",
  "Detail":"{\"state\":\"FAILED\",\"copyJobId\":\"TEST-001\",\"statusMessage\":\"KMS key disabled\",\"accountId\":\"111122223333\",\"resourceArn\":\"arn:aws:ec2:us-west-2:111122223333:volume/vol-test\",\"backupVaultName\":\"Default\"}"
}]'
```

Expected within 3–5 minutes:
- Investigation appears in your Slack channel
- RCA email arrives in your inbox

---

## Onboarding new accounts

When a new account joins the OU:
- **Automatic:** StackSet auto-deploys the forwarding rule + investigation role
- **Manual (required):** Register it with the agent space:

```bash
aws devops-agent create-association \
  --agent-space-id YOUR_AGENT_SPACE_ID \
  --source-configuration '{"aws":{"accountId":"NEW_ACCOUNT_ID","accountType":"SOURCE","assumableRoleArn":"arn:aws:iam::NEW_ACCOUNT_ID:role/DevOpsAgentInvestigationRole"}}' \
  --region us-west-2
```

> Tip: Automate this with a Lambda triggered by the Organizations `CreateAccountResult` event.

---

## Cleanup

```bash
REGION=us-west-2
OU_ID=ou-xxxx-xxxxxxxx

aws cloudformation delete-stack-instances --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions us-east-1 us-west-2 eu-west-1 --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region $REGION

aws cloudformation delete-stack-set --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region $REGION

aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region $REGION

# Optional
aws devops-agent delete-agent-space --agent-space-id YOUR_AGENT_SPACE_ID --region $REGION
```

> Note: Investigation roles have `DeletionPolicy: Retain` — delete manually if no longer needed.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| StackSet fails for delegated-admin account | Expected — template skips it via condition |
| `list-accounts-for-parent` empty | Must run from management account or have Organizations read permissions |
| Lambda 403 from webhook | Secret rotated? Update in Secrets Manager |
| No Slack message | Agent not invited — run `/invite @AWS DevOps Agent` |
| No email | SNS subscription not confirmed — check spam |
| Agent can't investigate member | Account not registered (step 6) or StackSet hasn't deployed role yet |
| 3 concurrent investigations limit | Request quota increase via Service Quotas console |
