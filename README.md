# AWS Backup DevOps Agent v9

Automated backup failure investigation for your entire AWS Organization. Deploy once from the delegated admin — every failed backup job gets an autonomous root cause analysis delivered to Slack and email.

## Architecture

```
Member Accounts (auto via StackSet)       Delegated Admin (deploy here)
┌──────────────────────────────┐         ┌─────────────────────────────────────┐
│ Backup Job FAILS             │         │                                     │
│      │                       │ forward │  EventBridge → Lambda → Webhook     │
│      ▼                       │────────▶│                              │      │
│ EventBridge Rule             │         │                              ▼      │
│ (per region, auto-deployed)  │         │                     DevOps Agent    │
│                              │         │                        │    │       │
│ DevOpsAgentInvestigationRole │◀────────│────── investigates ────┘    │       │
│ (read-only, AWS-managed)     │         │                             ▼       │
└──────────────────────────────┘         │                    Slack + Email    │
                                         └─────────────────────────────────────┘
```

## Quick Start

```bash
git clone https://github.com/kukkunuruanil/aws-backup-devops-agent-v9.git
cd aws-backup-devops-agent-v9
./deploy.sh
```

The script automates 7 steps, pausing only for webhook creation (console) and reminding you to connect Slack.

## Prerequisites

- Delegated admin for **AWS Backup** and **CloudFormation StackSets**
- AWS DevOps Agent access
- AWS CLI v2 with delegated admin credentials
- Slack workspace (admin access)

### One-time (from management account):

```bash
aws organizations register-delegated-administrator \
  --account-id YOUR_DELEGATED_ADMIN_ID \
  --service-principal member.org.stacksets.cloudformation.amazonaws.com
```

## What Gets Deployed

**Delegated admin (`main-stack.yaml`):**

| Resource | Purpose |
|----------|---------|
| `BackupFailureBridge` Lambda | Signs events → posts to agent webhook |
| `BackupRCAEmailer` Lambda | Formats RCA → publishes to SNS |
| EventBridge rules (2) | Backup failures + investigation complete |
| EventBus policy | Accepts events from org |
| SNS topic + email sub | RCA delivery |
| Secrets Manager secret | Webhook credentials |

**Member accounts (`member-forwarder.yaml` via StackSet):**

| Resource | Purpose |
|----------|---------|
| EventBridge rule (per region) | Forwards FAILED/ABORTED/EXPIRED events |
| `BackupEventForwardingRole` | Cross-account event delivery |
| `DevOpsAgentInvestigationRole` | Agent assumes this for read-only investigation (uses `AIDevOpsAgentAccessPolicy`) |

## Key Improvements (v9 vs v8)

- **Correct trust model** — investigation role trusts `aidevops.amazonaws.com` (not a custom IAM role)
- **AWS-managed permissions** — uses `AIDevOpsAgentAccessPolicy` (respects the agent's permission guardrail)
- **Secondary account registration** — script registers each member account with the agent space
- **Email delivery** — RCA summaries via SNS on investigation complete
- **Clean templates** — no unused parameters or version label drift

## Manual Steps (cannot be automated)

| Step | Why |
|------|-----|
| Webhook secret | Generated server-side, shown once |
| Slack OAuth | Browser-based flow |
| SNS email confirm | Requires human click |

## Cleanup

```bash
aws cloudformation delete-stack-instances --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions us-east-1 us-west-2 eu-west-1 --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region us-west-2

aws cloudformation delete-stack-set --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region us-west-2

aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region us-west-2
```

## Docs

- [IMPLEMENTATION_GUIDE.md](IMPLEMENTATION_GUIDE.md) — full step-by-step with explanations
- [AWS DevOps Agent docs](https://docs.aws.amazon.com/devopsagent/latest/userguide/)
- [Connecting multiple AWS accounts](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-integrations-and-knowledge-connecting-multiple-aws-accounts.html)
