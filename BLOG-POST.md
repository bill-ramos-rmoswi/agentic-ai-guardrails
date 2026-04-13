# The Hitchhiker's Guide to Agentic AI in AWS: Don't Panic, But Definitely Don't Let the Agent Deploy to PROD

*How one real-world incident became a practical pattern for giving AI agents safe access to databases, application servers, and AWS infrastructure.*

> "Don't Panic."
>
> — *The Hitchhiker's Guide to the Galaxy*

There is a special kind of silence that happens after you realize an AI agent has just deployed code to the wrong environment.

Not a dramatic silence. Not the cinematic kind. More the sort of silence that says, very clearly, "well, that was not in the runbook."

In our case, the agent was supposed to help investigate and validate a migration-related issue in UAT. Instead, it executed AWS Systems Manager commands against the production application server, changed the Git branch to an experimental compatibility branch, restarted services, and effectively gave us the most aggressive UAT test possible: the code ran in production for about 18 hours.

No customer-facing outage followed. No data loss occurred. In fact, the surprise was the opposite: the migration branch included performance improvements and new indexes intended for the target Aurora MySQL environment, and the existing production workload on RDS MariaDB actually ran faster during that window. What began as an unauthorized production change turned into an accidental live-fire performance validation. Once we discovered the production branch had been switched to the migration branch, we quickly reverted, started the investigation, and then carried those lessons into a much safer rollout model. But the lesson was clear:

**The problem was not that the code was bad; in this case, it actually improved performance. The problem was that the path to production was uncontrolled.**

That is the point of this post.

This is not a post about why agentic AI is dangerous. It is a post about how to use agents safely for exactly the kind of work they are good at:

- investigating application bugs
- diagnosing database performance issues
- testing fixes in UAT
- generating production diagnostics
- preparing break-glass scripts for human review

This is also a post about one of the most important truths in platform engineering:

**If you are going to let agents touch infrastructure, your architecture has to be better than their assumptions.**

---

## The Incident: Or, How We Accidentally Performed the Ultimate UAT Test

Here is the short version.

An AI coding agent was working on a MySQL 8.0 compatibility issue in an open-source ERP workload that only supported MariaDB. The plan was sensible enough:

1. identify the issue
2. push the fix branch
3. pull it onto UAT
4. restart services
5. run `bench migrate`
6. validate the behavior

The agent even described its intent as "MyApp-UAT."

The trouble was that the instance it targeted was actually the production EC2 instance.

That happened because the environment had several ambiguity traps:

- production and non-production resources were historically co-located
- a legacy AWS profile could reach both UAT and PROD paths
- the instance was involved in migration testing patterns that blurred environment identity
- there was no machine-enforced pre-flight check saying, "this is PROD, stop now"

The agent did not behave maliciously. It behaved like an agent with enough permissions, incomplete environmental context, and no hard stop between "I think this is UAT" and "I am now modifying PROD."

The strange part is that the first signal was not alarms or outages. It was performance. Users were not suddenly filing trouble tickets. If anything, the system looked happier. Later, when the intended performance fixes were rolled out properly, users were very happy with the result. There is a certain eerie quality to a quiet help desk after a release.

That does not make the incident acceptable. It makes it more instructive.

Because the lesson is not "sometimes you get lucky, so relax." The lesson is "even when the outcome is positive, accidental production change is still a control failure."

And fortunately, it has a very practical solution.

---

## Why This Incident Matters Even More Because It Worked

It would be easy to tell the wrong story here.

The wrong story would be:

> The branch made production faster, so maybe it was not really a problem.

No.

It was absolutely a problem.

A positive outcome does not excuse an uncontrolled execution path. If the exact same lack of controls had applied a harmful migration, dropped a needed index, or restarted the wrong service at the wrong time, we would be telling a very different story.

What the happy ending does give us is something unusually valuable:

- a real incident
- a real production blast-radius failure
- a real example of accidental live validation
- and a real opportunity to design better agent guardrails without pretending the technology is either magic or doom

That is why this pattern matters.

## The Design Goal

We did not want to respond by banning agents from infrastructure work.

That would be throwing away the good part.

Agents are genuinely useful for:

- narrowing the scope of a performance issue
- collecting logs and configuration state
- proposing code fixes
- applying changes in UAT
- validating schema or deployment behavior
- generating operational scripts for humans to approve

What we wanted instead was a model that looked like this:

### In UAT
The agent should be able to move quickly and operate with very little friction.

### In PROD
The agent should be able to observe, diagnose, and prepare actions, but not directly perform write operations.

### If break-glass help is needed in PROD
The agent can generate the exact script or command sequence, but a human reviews and executes it.

That becomes the core pattern:

**full agency in UAT, constrained diagnostics in PROD, human-approved execution for any production write path.**

---

## The Three Layers of Guardrails

We implemented three complementary layers.

1. **Resource identity** through tags and naming
2. **Access control** through IAM policy denial
3. **Execution control** through custom SSM documents

None of these is sufficient by itself. Together, they create a system where a mistaken assumption by the agent is no longer enough to cause a production change.

---

## Layer 1: Make the Environment Machine-Readable

The first problem was embarrassingly simple: the environment boundary lived mostly in human heads.

That is not good enough for automation, and it is definitely not good enough for agents.

So the first step was to make environment identity explicit using tags.

### Tag every instance with `Environment`

```bash
#!/bin/bash
# deploy-instance-tags.sh
# Tags EC2 instances so policies and automation can distinguish PROD from UAT.

set -euo pipefail

echo "Tagging PROD"
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60001 \
  --tags Key=Environment,Value=PROD \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "Tagging legacy UAT"
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60002 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "Tagging UAT2"
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60003 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "Tagging UAT3"
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60004 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "Tagging current UAT account instance"
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60005 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-UAT \
  --region us-west-2
```

This is almost boring infrastructure hygiene, which is exactly why it matters.

Tags are not decoration. They become the trust anchor for everything that follows.

If your agent asks, "what am I allowed to do here?", the answer should come from a machine-verifiable property like `Environment=PROD`, not a naming convention or a path that "usually means UAT."

### Pre-flight identity check

Before any remote command is sent, require an explicit instance verification step.

```bash
aws ec2 describe-instances \
  --instance-ids i-0a1b2c3d4e5f60001 \
  --profile AcmeCo-PROD \
  --region us-west-1 \
  --query 'Reservations[0].Instances[0].[InstanceId,Tags[?Key==`Name`].Value|[0],Tags[?Key==`Environment`].Value|[0]]' \
  --output table
```

A human can read that. An agent can read that. More importantly, an IAM policy and an SSM document can use it too.

---

## Layer 2: Deny the Dangerous Path in IAM

Tags by themselves are informational.

The second layer turns them into a hard control.

The idea is simple:

**If an instance is tagged as production, deny remote execution actions regardless of what the agent thinks it is doing.**

### IAM deny policy for production-tagged instances

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenySSMWriteOnPRODTaggedInstances",
      "Effect": "Deny",
      "Action": [
        "ssm:SendCommand",
        "ssm:StartSession",
        "ssm:StartAutomationExecution"
      ],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": {
        "StringEqualsIgnoreCase": {
          "ssm:resourceTag/Environment": ["PROD", "production", "prod"]
        }
      }
    },
    {
      "Sid": "DenySSMWriteOnSpecificPRODInstances",
      "Effect": "Deny",
      "Action": [
        "ssm:SendCommand",
        "ssm:StartSession"
      ],
      "Resource": [
        "arn:aws:ec2:us-west-1:111122223333:instance/i-0a1b2c3d4e5f60001"
      ]
    }
  ]
}
```

Two details matter here.

### 1. Tag-based deny is the long-term scalable control
If you add new production instances later, the policy still works as long as tagging discipline is maintained.

### 2. Specific-instance deny is the tactical backstop
This protects you even before your environment tagging is perfect.

The important design principle is this:

**Do not rely on tool prompts or good intentions when AWS can enforce the boundary directly.**

The agent should not need to remember that production is special. The platform should remember it for the agent.

---

## Layer 3: Replace Raw SSM with Safer Execution Documents

There is a big difference between saying:

> "The agent can run shell commands"

and saying:

> "The agent can run shell commands only through controlled execution paths that validate context first."

That is where Systems Manager documents help.

Instead of allowing the agent to use `AWS-RunShellScript` directly for everything, create custom documents that encode your safety rules.

We created two.

- `AcmeCo-SafeRunShellScript` for non-production execution
- `AcmeCo-ProdDiagnostics` for production read-only diagnostics

### Document 1: Safe execution for UAT and non-PROD

This document blocks execution on instances tagged as `PROD` and also blocks untagged instances.

That last part is important.

**Untagged should default to unsafe.**

```yaml
---
schemaVersion: "2.2"
description: |
  Environment-safe shell script execution. Refuses execution on PROD or untagged instances.

parameters:
  commands:
    type: StringList
  workingDirectory:
    type: String
    default: ""
  executionTimeout:
    type: String
    default: "3600"

mainSteps:
  - action: aws:runShellScript
    name: ValidateEnvironment
    inputs:
      timeoutSeconds: "30"
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail

          TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 30")
          INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/instance-id)
          REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/placement/region)
          ENV_TAG=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/tags/instance/Environment 2>/dev/null || echo "QUERY_FAILED")

          if echo "$ENV_TAG" | grep -qi "404\|not found\|error"; then ENV_TAG="QUERY_FAILED"; fi
          ENV_LOWER=$(echo "$ENV_TAG" | tr '[:upper:]' '[:lower:]')

          if [[ "$ENV_LOWER" == "prod" || "$ENV_LOWER" == "production" ]]; then
            echo "BLOCKED: Instance is production"
            exit 1
          fi

          if [[ "$ENV_TAG" == "None" || "$ENV_TAG" == "QUERY_FAILED" || -z "$ENV_TAG" ]]; then
            echo "BLOCKED: Instance is untagged or tag lookup failed"
            exit 1
          fi

          echo "APPROVED: Environment=$ENV_TAG"

  - action: aws:runShellScript
    name: ExecuteCommands
    inputs:
      timeoutSeconds: "{{ executionTimeout }}"
      workingDirectory: "{{ workingDirectory }}"
      runCommand: "{{ commands }}"
```

### Example use in UAT

```bash
aws ssm send-command \
  --document-name AcmeCo-SafeRunShellScript \
  --instance-ids i-0a1b2c3d4e5f60003 \
  --parameters 'commands=["hostname","cd /home/acmeco/bench && sudo -u acmeco bench --site erp.uat.example.com migrate"]' \
  --profile AcmeCo-PROD \
  --region us-west-1
```

This gives the agent a powerful but bounded path:

- yes to UAT execution
- no to PROD
- no to mystery instances

That alone removes a huge amount of operational risk.

---

## Production Should Be Observable, Not Mutable

The next requirement was more subtle.

We did not want the agent blind in production. That would make diagnostics slower and push too much routine work back to humans.

But we also did not want the agent to be able to run write operations in production.

So we created a second document specifically for production diagnostics.

### Document 2: PROD read-only diagnostics

This document does two things:

1. verifies that the target instance is actually PROD
2. checks the command text against a blocklist of write-style operations

```yaml
---
schemaVersion: "2.2"
description: |
  PROD-only read-only diagnostics.

parameters:
  commands:
    type: String
  workingDirectory:
    type: String
    default: ""
  executionTimeout:
    type: String
    default: "300"

mainSteps:
  - action: aws:runShellScript
    name: ValidateEnvironmentIsPROD
    inputs:
      timeoutSeconds: "30"
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail

          TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
            -H "X-aws-ec2-metadata-token-ttl-seconds: 30")
          ENV_TAG=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
            http://169.254.169.254/latest/meta-data/tags/instance/Environment 2>/dev/null || echo "QUERY_FAILED")
          ENV_LOWER=$(echo "$ENV_TAG" | tr '[:upper:]' '[:lower:]')

          if [[ "$ENV_LOWER" != "prod" && "$ENV_LOWER" != "production" ]]; then
            echo "BLOCKED: This document is for PROD only"
            exit 1
          fi

  - action: aws:runShellScript
    name: ValidateCommandsSafe
    inputs:
      timeoutSeconds: "30"
      runCommand:
        - |
          #!/bin/bash
          set -euo pipefail

          COMMANDS="{{ commands }}"

          if echo "$COMMANDS" | grep -qiE 'bench\s+(migrate|restart|update|setup|install|build)'; then
            echo "BLOCKED: Bench write operation detected"
            exit 1
          fi

          if echo "$COMMANDS" | grep -qiE 'git\s+(checkout|merge|reset|pull|fetch|push|rebase|commit)'; then
            echo "BLOCKED: git write operation detected"
            exit 1
          fi

          if echo "$COMMANDS" | grep -qE '(>\s|>>|[^2]>\s|&>|\btee\b)'; then
            echo "BLOCKED: output redirection detected"
            exit 1
          fi

          if echo "$COMMANDS" | grep -qiE 'systemctl\s+(start|stop|restart)|supervisorctl\s+(restart|start|stop)'; then
            echo "BLOCKED: service control operation detected"
            exit 1
          fi

          echo "APPROVED: command is read-only"

  - action: aws:runShellScript
    name: ExecuteDiagnostics
    inputs:
      timeoutSeconds: "{{ executionTimeout }}"
      workingDirectory: "{{ workingDirectory }}"
      runCommand:
        - |
          eval "{{ commands }}"
```

### Example allowed commands in PROD

```bash
aws ssm send-command \
  --document-name AcmeCo-ProdDiagnostics \
  --instance-ids i-0a1b2c3d4e5f60001 \
  --parameters 'commands=tail -100 /var/log/syslog' \
  --profile AcmeCo-PROD \
  --region us-west-1
```

```bash
aws ssm send-command \
  --document-name AcmeCo-ProdDiagnostics \
  --instance-ids i-0a1b2c3d4e5f60001 \
  --parameters 'commands=cd /home/acmeco/bench/apps/acmeco_erp && git log --oneline -10' \
  --profile AcmeCo-PROD \
  --region us-west-1
```

### Example blocked commands in PROD

```bash
# blocked: write operation
aws ssm send-command \
  --document-name AcmeCo-ProdDiagnostics \
  --instance-ids i-0a1b2c3d4e5f60001 \
  --parameters 'commands=bench restart' \
  --profile AcmeCo-PROD \
  --region us-west-1
```

```bash
# blocked: write operation
aws ssm send-command \
  --document-name AcmeCo-ProdDiagnostics \
  --instance-ids i-0a1b2c3d4e5f60001 \
  --parameters 'commands=git checkout main' \
  --profile AcmeCo-PROD \
  --region us-west-1
```

This gives you a very useful mode of operation:

**the agent can help you understand PROD, but it cannot change PROD.**

That is a much healthier boundary.

---

## Hardening the Human-Side Tooling Too

Not every guardrail belongs in AWS.

Some should exist in the tools the agent uses.

We also updated the local tool configuration to deny obvious dangerous patterns, such as:

- direct SSM command execution to the known PROD instance ID
- direct SSM execution using the production profile
- legacy ambiguous profile usage

Conceptually, this looked like:

```json
{
  "deny": [
    "Bash(aws ssm send-command*i-0a1b2c3d4e5f60001*)",
    "Bash(aws ssm start-session*i-0a1b2c3d4e5f60001*)",
    "Bash(aws ssm send-command*AcmeCo-PROD*)",
    "Bash(aws ssm start-session*AcmeCo-PROD*)",
    "Bash(*--profile AcmeCo --*)"
  ]
}
```

This layer is not sufficient by itself, but it is still worth doing.

Think of it as the towel in your bag: not your main line of defense, but something you will be very glad to have when things get strange.

---

## Control Tower Is the Real Long-Term Answer

All of the controls above are good and useful.

But let us be honest: the cleanest solution is still **better account separation**.

The long-term target state is a standard AWS multi-account pattern:

- separate AWS accounts for PROD and UAT
- separate permission sets and roles
- SCPs at the OU level
- environment-specific CI/CD paths
- no ambiguous cross-environment execution identity

In other words:

**make it structurally hard to be wrong.**

If an agent authenticated into the UAT account physically cannot touch the PROD account, you have reduced the blast radius dramatically before the first command is even generated.

This is where AWS Control Tower becomes more than governance overhead. It becomes an agent safety architecture.

---

## A Safer Operating Model for Agentic Workflows

At this point, the model becomes straightforward.

### DEV
The agent can do almost anything reasonable.

### UAT
The agent can deploy branches, restart services, run migrations, validate fixes, and generate evidence.

### PROD
The agent can inspect logs, configuration, process state, query status, and produce recommendations.

### PROD write access
The agent does not execute. The agent prepares.

That final part is what makes the model practical.

---

## Break Glass: Human-in-the-Loop Scripts for PROD

There are cases where you may genuinely want an agent's help with a production issue.

For example:

- gather the exact diagnostics needed to evaluate a rollback
- draft the commands to revert a branch
- build a read-only SQL script to validate a suspicion
- propose a safe sequence for a planned maintenance window

In those situations, the right pattern is not to give the agent direct write access. It is to have the agent generate a script that a human reviews and runs.

### Example: agent-generated production rollback script

```bash
#!/bin/bash
# break-glass-prod-rollback.sh
# Human-reviewed rollback script for controlled PROD execution.

set -euo pipefail

PROFILE="AcmeCo-PROD"
REGION="us-west-1"
INSTANCE_ID="i-0a1b2c3d4e5f60001"
TARGET_BRANCH="version-15"

echo "Verifying target instance before rollback..."
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].[InstanceId,PrivateIpAddress,Tags[?Key==`Name`].Value|[0],Tags[?Key==`Environment`].Value|[0]]' \
  --output table

echo "About to revert PROD application code to $TARGET_BRANCH"
read -p "Type YES to continue: " CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
  echo "Aborted."
  exit 1
fi

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --parameters "commands=[\"cd /home/acmeco/bench/apps/acmeco_erp && sudo -u acmeco git checkout $TARGET_BRANCH && sudo -u acmeco git log --oneline -5\",\"cd /home/acmeco/bench && sudo -u acmeco bench restart\"]" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'Command.CommandId' \
  --output text)

echo "Rollback command submitted: $COMMAND_ID"
echo "Fetching command result..."
sleep 10

aws ssm get-command-invocation \
  --command-id "$COMMAND_ID" \
  --instance-id "$INSTANCE_ID" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query '[Status,StandardOutputContent,StandardErrorContent]' \
  --output json
```

Notice what changed.

The agent can draft this script, explain the expected effect, and identify the likely recovery path.

But a human still:

- verifies the target instance
- chooses to continue
- executes the command
- owns the change window

That is the right division of labor.

---

## What We Tested

A guardrail you do not test is just an optimistic story.

So we validated the controls explicitly.

### Expected behavior

- SafeRunShellScript on PROD: blocked
- ProdDiagnostics on PROD with `hostname`: allowed
- ProdDiagnostics on PROD with `tail /var/log/syslog`: allowed
- ProdDiagnostics on PROD with `bench restart`: blocked
- ProdDiagnostics on PROD with `git checkout`: blocked
- ProdDiagnostics on PROD with `echo > file`: blocked

### Example validation script

```bash
#!/bin/bash
# test-prod-safeguards.sh

set -euo pipefail

PROFILE="AcmeCo-PROD"
REGION="us-west-1"
PROD_INSTANCE="i-0a1b2c3d4e5f60001"

aws ssm send-command \
  --document-name AcmeCo-SafeRunShellScript \
  --instance-ids "$PROD_INSTANCE" \
  --parameters 'commands=["hostname"]' \
  --profile "$PROFILE" \
  --region "$REGION"

aws ssm send-command \
  --document-name AcmeCo-ProdDiagnostics \
  --instance-ids "$PROD_INSTANCE" \
  --parameters 'commands=hostname' \
  --profile "$PROFILE" \
  --region "$REGION"

aws ssm send-command \
  --document-name AcmeCo-ProdDiagnostics \
  --instance-ids "$PROD_INSTANCE" \
  --parameters 'commands=bench restart' \
  --profile "$PROFILE" \
  --region "$REGION"
```

In our validation, the protections behaved as intended: diagnostics were allowed, write-like commands were blocked, and PROD execution through the non-production wrapper failed as expected.

That is the standard you want.

Not "probably safe."

**Provably constrained.**

---

## Design Principles You Can Reuse

If you are building agentic workflows in AWS, here are the principles I would carry into any customer environment.

### 1. Let tags become policy inputs
If your infrastructure cannot say what environment it belongs to, your agent controls will always be fragile.

### 2. Deny in AWS, not just in prompts
Tool instructions are useful. IAM is better.

### 3. Replace generic execution paths with environment-aware wrappers
Do not hand an agent `AWS-RunShellScript` and hope for the best.

### 4. Make untagged equal unsafe
When the environment is ambiguous, fail closed.

### 5. Give agents broad access in UAT, narrow access in PROD
That is the sweet spot between speed and safety.

### 6. Keep humans in the loop for production writes
Use agents to generate, explain, and prepare. Use humans to approve and execute.

### 7. Prefer structural separation over clever safeguards
Separate accounts beat clever regex every time.

---

## What This Looks Like in Practice

Here is the operational pattern I now recommend.

### Agent permissions by environment

| Environment | Agent capability model |
|---|---|
| DEV | broad access |
| UAT | deploy, restart, migrate, validate |
| PROD | diagnostics only |
| PROD write actions | human-reviewed break-glass script |

### Suggested command paths

| Action type | Recommended path |
|---|---|
| UAT deployment | `AcmeCo-SafeRunShellScript` |
| UAT migration | `AcmeCo-SafeRunShellScript` |
| PROD diagnostics | `AcmeCo-ProdDiagnostics` |
| PROD write/change | human-reviewed script in approved window |

The goal is not to eliminate agent autonomy.

The goal is to **place it where it is most valuable and least dangerous.**

---

## So Long, and Thanks for All the Guardrails

The incident that prompted this post was real, uncomfortable, and extremely educational.

It also ended up being useful.

It gave us a practical framework for answering a question many teams are about to face:

**How do you let AI agents help with real infrastructure and database work without giving them a straight-line path to production mistakes?**

My answer is now pretty simple:

- identify environments explicitly
- deny production write paths in IAM
- route execution through safe wrappers
- allow agents to move quickly in UAT
- require humans to approve production mutations
- use account boundaries to make the entire system harder to misuse

Or, if you prefer the shorter Hitchhiker's Guide version:

**Don't Panic. But absolutely do add guardrails before you hand your agent the keys to AWS.**

---

## Appendix: Quick-Start Artifacts

All scripts and SSM documents from this post are available in the companion GitHub repository:

**[https://github.com/bill-ramos-rmoswi/agentic-ai-guardrails](https://github.com/bill-ramos-rmoswi/agentic-ai-guardrails)**

### Deploy the environment tags

```bash
bash deploy-instance-tags.sh
```

### Register the SSM safety documents

```bash
bash deploy-ssm-document.sh
```

### Validate production safeguards off-hours

```bash
bash test-prod-safeguards.sh
```

### Deploy the IAM deny policy

```bash
bash deploy-iam-deny-policy.sh
```

---

## Author's Note

If you are working on AI-assisted database modernization, cloud migration, or operational automation, I think this pattern is going to become increasingly normal:

- agents for acceleration
- guardrails for containment
- humans for accountability

That is not a compromise. It is the design.

And in my experience, it is a much better answer than either extreme of "let the agent do everything" or "never let the agent near infrastructure at all."

The Guide would probably approve.

Or at least tell you to keep a towel near your IAM policies.

---

## 📚 References & Further Reading (For Those Who Actually Read the Manual)

If you would like to verify that none of this is completely made up (and that AWS has been quietly telling us to do this all along), here are some relevant resources:

### 🔐 Identity, Access, and Guardrails
- AWS IAM Best Practices
  https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html

- Attribute-Based Access Control (ABAC) for AWS
  https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html

- IAM Policy Elements: Condition
  https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_elements_condition.html

These are the documents that justify using tags like `Environment=PROD` as actual enforcement mechanisms, not just decorative metadata.

---

### 🖥️ Systems Manager (SSM) and Safe Remote Execution
- AWS Systems Manager Run Command
  https://docs.aws.amazon.com/systems-manager/latest/userguide/execute-remote-commands.html

- AWS Systems Manager Best Practices
  https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-best-practices.html

- Using AWS Systems Manager Session Manager Securely
  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html

These reinforce the idea that unrestricted shell access is rarely a good idea, and that controlled execution paths are preferable.

---

### 🏢 Multi-Account Strategy and Control Tower
- AWS Control Tower Overview
  https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html

- Organizing Your AWS Environment Using Multiple Accounts
  https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html

- Service Control Policies (SCPs)
  https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_policies_scps.html

If you take one thing from this section, it is this: the best guardrail is often a completely different account.

---

### 🧭 AWS Well-Architected Framework
- AWS Well-Architected Framework
  https://docs.aws.amazon.com/wellarchitected/latest/framework/welcome.html

- Operational Excellence Pillar
  https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html

- Security Pillar
  https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/welcome.html

These documents are where phrases like "limit blast radius" and "automate safely" come from. They apply just as much to agents as they do to humans.

---

### 🤖 A Note on Agents and the Future

AWS does not yet publish a single "Agent Safety Guide."

But if you read the documents above carefully, you will notice something interesting:

- everything assumes automation will make changes
- everything emphasizes guardrails over intent
- everything assumes mistakes will happen

Which means the model already exists.

We are just applying it to agents instead of scripts.

Or, to put it in Hitchhiker's Guide terms:

> The answer was always 42. We just had to ask a better question.

In this case, the better question is:

**"What happens when the thing making the change is confident, fast, and occasionally wrong?"**

Design for that, and everything else tends to fall into place.
