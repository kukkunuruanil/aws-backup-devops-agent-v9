# Automating AWS Backup failure investigations with AWS DevOps Agent

*By Anil Kukkunur, Solutions Architect, AWS*

> **Content level:** 300 (Advanced) · **Reading time:** ~12 minutes · **Time to deploy:** ~15 minutes
>
> *AWS DevOps Agent is in preview. Feature names, console screens, and APIs referenced in this post may change before general availability.*

## Introduction

If you run [AWS Backup](https://aws.amazon.com/backup/) across an [AWS Organizations](https://aws.amazon.com/organizations/) environment, you have probably felt the pain of a failed backup job. When a job fails in one of dozens—or hundreds—of accounts, someone has to notice the failure, assume a role into the right account, read through [AWS CloudTrail](https://aws.amazon.com/cloudtrail/) events, check the [AWS Key Management Service (AWS KMS)](https://aws.amazon.com/kms/) key policy, and confirm that the [AWS Identity and Access Management (IAM)](https://aws.amazon.com/iam/) role still has the permissions it needs. That investigation is repetitive, and it often happens after hours.

In this post, I show you how to hand that investigation to [AWS DevOps Agent](https://aws.amazon.com/devops-agent/), an autonomous agent that triages incidents, correlates signals across your environment, and produces a root cause analysis (RCA). You build an event-driven pipeline that detects a failed backup or copy job anywhere in your organization, triggers AWS DevOps Agent to investigate the failure in the account where it happened, and delivers the RCA to both Slack and email.

## The use case

Picture a platform team that owns backup compliance for a large organization. Backups run in many member accounts across several Regions. Today, when a job fails, the team finds out from a dashboard review or a support ticket, and a human starts digging. Common root causes include:

- An AWS KMS key used by a backup vault was disabled or had its key policy changed.
- An IAM role lost a permission after a policy update.
- A source resource was deleted or modified before the backup window.
- A vault lock or Region setting blocked a copy job.

Each of these has a clear signal in CloudTrail or in the resource's configuration—but only if you know where to look. The goal of this solution is to remove that manual first pass entirely.

## Architecture

The solution uses a hub-and-spoke pattern built on [Amazon EventBridge](https://aws.amazon.com/eventbridge/), [AWS Lambda](https://aws.amazon.com/lambda/), [Amazon Simple Notification Service (Amazon SNS)](https://aws.amazon.com/sns/), and [AWS CloudFormation StackSets](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/what-is-cfnstacksets.html).

**[FIGURE 1]** *End-to-end architecture: member accounts forward AWS Backup failure events through Amazon EventBridge to the delegated administrator account, where AWS Lambda calls AWS DevOps Agent, which investigates and returns an RCA to Slack and email.*

The flow:

1. A backup or copy job fails in a member account (any Region).
2. An EventBridge rule in that account matches the `FAILED`, `ABORTED`, or `EXPIRED` state and forwards the event to the delegated administrator's central event bus.
3. An EventBridge rule in the delegated administrator account invokes a Lambda function.
4. The Lambda function signs the event and posts it to the AWS DevOps Agent webhook.
5. AWS DevOps Agent assumes a cross-account role into the member account, investigates, and posts the RCA to Slack.
6. When the investigation completes, a second EventBridge rule invokes an emailer Lambda function that publishes the RCA summary to an SNS topic.

## Setting up AWS DevOps Agent

Everything lives in the delegated administrator account. Three pieces to configure:

**Create the agent space.** In the AWS DevOps Agent console, create an agent space named `BackupInvestigations`. Then create an IAM role (`DevOpsAgentBackupRole`) that trusts the `aidevops.amazonaws.com` service principal, scoped by `aws:SourceAccount` and `aws:SourceArn` to your agent space. Attach the AWS-managed `AIDevOpsAgentAccessPolicy`. Associate the account with the agent space.

**Create the webhook.** In the agent space, create an HMAC webhook. Copy the URL and secret—the secret is shown only once. The deployment script stores both in [AWS Secrets Manager](https://aws.amazon.com/secrets-manager/).

**Connect Slack.** Register Slack as a capability provider and complete the OAuth authorization for your workspace. Invite the agent to your channel with `/invite @AWS DevOps Agent`.

## Creating the EventBridge rule and Lambda that start an investigation

The [AWS CloudFormation](https://aws.amazon.com/cloudformation/) template creates an EventBridge rule on the default event bus:

```yaml
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
```

The rule targets a Lambda function, `BackupFailureBridge`, which reads the webhook secret from Secrets Manager, shapes the backup event into the incident payload that AWS DevOps Agent expects, and signs the request with an HMAC signature before posting it.

## Forwarding failure events from member accounts

You deploy a lightweight forwarding rule in every member account and Region using a service-managed CloudFormation StackSet. With auto-deployment enabled, any account joining the target OU gets the rule automatically.

The forwarding rule uses the same event pattern and targets the delegated administrator's event bus. Cross-account delivery uses an EventBus resource policy that accepts events scoped by `aws:PrincipalOrgID`.

Because EventBridge rules are Regional, the StackSet deploys the forwarding rule to every Region you select, while the IAM forwarding role (global) is created only once per account.

## Granting AWS DevOps Agent cross-account investigation permissions

For the agent to investigate in the account where the failure happened, each member account needs an investigation role. The same StackSet creates `DevOpsAgentInvestigationRole` with:

- **Trust policy:** trusts the `aidevops.amazonaws.com` service principal, scoped by `aws:SourceAccount` (your delegated admin account) and `aws:SourceArn` (your agent space ARN).
- **Permissions:** the AWS-managed `AIDevOpsAgentAccessPolicy`, which provides read-only access to the services the agent needs for investigation. AWS maintains this policy and updates it as new capabilities are added.

The agent enforces a permission guardrail (session policy) on every session—effective permissions are the intersection of your role's policies and this guardrail. This means the agent cannot perform write operations even if the role were misconfigured.

**Important:** Deploying the IAM role is not sufficient. You must also register each member account as a secondary source in the agent space:

```bash
aws devops-agent create-association \
  --agent-space-id $AGENT_SPACE_ID \
  --source-configuration "{\"aws\":{\"accountId\":\"$MEMBER_ID\",\"accountType\":\"SOURCE\",\"assumableRoleArn\":\"arn:aws:iam::${MEMBER_ID}:role/DevOpsAgentInvestigationRole\"}}" \
  --region $REGION
```

The deployment script loops through all accounts in the target OU and registers them automatically.

## Delivering the investigation to Slack and email

**Slack** is the interactive channel. The agent posts the investigation timeline and final RCA directly into your operations channel.

**Email** gives you a durable record. A second EventBridge rule matches the agent's `Investigation Complete` event and invokes the `BackupRCAEmailer` Lambda, which formats the RCA and publishes it to an SNS topic. Confirm the SNS subscription from your inbox after deployment.

## Deploying the solution

Clone the repository and run the deployment script:

```bash
git clone https://github.com/kukkunuruanil/aws-backup-devops-agent-v9.git
cd aws-backup-devops-agent-v9
./deploy.sh
```

The script performs seven steps:

1. Creates or reuses the DevOps Agent space
2. Creates the primary IAM role and associates the account
3. Pauses for you to create the webhook (console — secret shown only once)
4. Deploys the main CloudFormation stack
5. Deploys the StackSet to all member accounts and Regions
6. Registers each member account as a secondary source for investigation
7. Sends a test event and reminds you to connect Slack

Only three actions require your hands: copying the webhook secret, completing Slack OAuth, and confirming the SNS email subscription.

## Validating the solution

Send a synthetic failure event:

```bash
aws events put-events --region us-west-2 --entries '[{
  "Source": "aws.backup",
  "DetailType": "Copy Job State Change",
  "Detail": "{\"state\":\"FAILED\",\"copyJobId\":\"TEST-001\",\"statusMessage\":\"KMS key disabled\",\"accountId\":\"111122223333\",\"resourceArn\":\"arn:aws:ec2:us-west-2:111122223333:volume/vol-test\",\"backupVaultName\":\"Default\"}"
}]'
```

Within 3–5 minutes you should see an investigation in Slack and an RCA email.

## Scaling considerations

- **Concurrent investigations:** Default quota is 3 per agent space (adjustable via Service Quotas). If a fleet-wide event causes many simultaneous failures, investigations queue.
- **New accounts:** StackSet auto-deployment covers the forwarding rule and IAM role, but you must re-run the association loop (step 6) or automate it with a Lambda triggered by the Organizations `CreateAccountResult` event.
- **Agent space sizing:** AWS recommends scoping agent spaces to on-call boundaries. For very large organizations, consider multiple agent spaces per OU rather than one space covering all accounts.

## Cleaning up

```bash
aws cloudformation delete-stack-instances --stack-set-name BackupEventForwarder \
  --deployment-targets OrganizationalUnitIds=$OU_ID \
  --regions us-east-1 us-west-2 eu-west-1 --no-retain-stacks \
  --call-as DELEGATED_ADMIN --region us-west-2

aws cloudformation delete-stack-set --stack-set-name BackupEventForwarder \
  --call-as DELEGATED_ADMIN --region us-west-2

aws cloudformation delete-stack --stack-name BackupDevOpsAgent --region us-west-2
```

## Conclusion

In this post, you built an automated investigation pipeline for AWS Backup that spans your entire AWS Organizations environment. Member accounts forward failed backup and copy jobs to a central account through Amazon EventBridge, AWS Lambda triggers AWS DevOps Agent to investigate using a scoped, read-only cross-account IAM role with the AWS-managed `AIDevOpsAgentAccessPolicy`, and the resulting root cause analysis is delivered to both Slack and email. The pipeline is event-driven and deployed with CloudFormation StackSets, so it adds almost no cost while your backups are healthy.

To get started, clone the [repository](https://github.com/kukkunuruanil/aws-backup-devops-agent-v9) and run `./deploy.sh`.

---

*Anil Kukkunur is a Solutions Architect at AWS who helps customers build resilient data protection strategies with AWS Backup and AWS Organizations.*
