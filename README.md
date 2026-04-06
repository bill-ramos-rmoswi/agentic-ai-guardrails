# Agentic AI Guardrails for AWS

Companion artifacts for the Medium post:
**"The Hitchhiker's Guide to Agentic AI in Production: Guardrails for AWS CLI and SSM"**

> *How we accidentally improved production performance — and why that was still a failure.*

---

## What's in this repo

These scripts implement a three-layer guardrail model for giving AI agents safe access to AWS infrastructure. They were built in response to a real production incident where an agent executed SSM commands against a production EC2 instance instead of the intended UAT target.

| File | Purpose |
|---|---|
| `deploy-instance-tags.sh` | Tag EC2 instances with `Environment=PROD` or `Environment=UAT` — the trust anchor for everything else |
| `iam-deny-ssm-prod.json` | IAM deny policy that blocks SSM write actions on PROD-tagged instances |
| `deploy-iam-deny-policy.sh` | Attaches the IAM deny policy to your SSO permission set role |
| `ssm-safe-run-shell-script.yaml` | SSM document for UAT execution — blocks PROD and untagged instances |
| `ssm-prod-diagnostics.yaml` | SSM document for PROD — read-only diagnostics with a command blocklist |
| `deploy-ssm-document.sh` | Registers both SSM documents and runs UAT smoke tests |
| `test-prod-safeguards.sh` | Off-hours validation: confirms both documents behave as expected on PROD |

---

## How it works

### Layer 1 — Resource identity (tags)
Every EC2 instance gets an `Environment` tag (`PROD` or `UAT`). This makes environment identity machine-verifiable rather than a naming convention or a human assumption.

### Layer 2 — IAM deny policy
An inline deny policy blocks `ssm:SendCommand`, `ssm:StartSession`, and `ssm:StartAutomationExecution` on any instance tagged `Environment=PROD`. A specific-instance ARN deny provides a tactical backstop while tagging is rolled out.

### Layer 3 — Custom SSM documents
Two purpose-built documents replace raw `AWS-RunShellScript`:

- **`AcmeCo-SafeRunShellScript`** — intended for UAT and DEV. Validates the `Environment` tag at runtime and refuses execution if the instance is PROD or untagged.
- **`AcmeCo-ProdDiagnostics`** — intended for PROD. Validates the instance *is* PROD, then checks the command against an extensive blocklist of write operations before allowing execution.

---

## Deployment order

```bash
# 1. Tag your instances
bash deploy-instance-tags.sh

# 2. Deploy the IAM deny policy
bash deploy-iam-deny-policy.sh

# 3. Register the SSM documents (includes UAT smoke tests)
bash deploy-ssm-document.sh

# 4. Validate PROD safeguards off-hours
bash test-prod-safeguards.sh
```

---

## Adapting to your environment

Before running any script, update the following values to match your own AWS environment:

| Placeholder | Replace with |
|---|---|
| `AcmeCo-PROD` | Your AWS CLI profile for the PROD account |
| `AcmeCo-UAT` | Your AWS CLI profile for the UAT account |
| `i-0a1b2c3d4e5f60001` | Your PROD EC2 instance ID |
| `i-0a1b2c3d4e5f6000[2-5]` | Your UAT EC2 instance IDs |
| `111122223333` | Your PROD AWS account ID |
| `us-west-1` / `us-west-2` | Your AWS regions |
| `AcmeCo-SafeRunShellScript` | Your preferred SSM document name |
| `AcmeCo-ProdDiagnostics` | Your preferred SSM document name |

---

## The operating model

| Environment | Agent capability |
|---|---|
| DEV | broad access |
| UAT | deploy, restart, migrate, validate — via `AcmeCo-SafeRunShellScript` |
| PROD | diagnostics only — via `AcmeCo-ProdDiagnostics` |
| PROD write actions | human-reviewed break-glass script, run in approved change window |

---

## Key design principle

> **Do not rely on tool prompts or good intentions when AWS can enforce the boundary directly.**

The agent should not need to remember that production is special. The platform should remember it for the agent.

---

## Related reading

- [AWS IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [Attribute-Based Access Control (ABAC) for AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/introduction_attribute-based-access-control.html)
- [AWS Systems Manager Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/execute-remote-commands.html)
- [AWS Control Tower Overview](https://docs.aws.amazon.com/controltower/latest/userguide/what-is-control-tower.html)
- [Organizing Your AWS Environment Using Multiple Accounts](https://docs.aws.amazon.com/whitepapers/latest/organizing-your-aws-environment/organizing-your-aws-environment.html)

---

*Companion to the Medium post "The Hitchhiker's Guide to Agentic AI in Production."*
*Don't Panic. But absolutely do add guardrails before you hand your agent the keys to AWS.*
