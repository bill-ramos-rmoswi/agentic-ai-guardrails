#!/bin/bash
# deploy-iam-deny-policy.sh
# Attaches the SSM PROD deny policy to the SSO permission set role.
#
# BEFORE RUNNING: Update PROFILE and REGION to match your environment.
#
# Run with: bash deploy-iam-deny-policy.sh

set -euo pipefail

POLICY_PATH="./iam-deny-ssm-prod.json"
POLICY_NAME="DenySSMWriteToPROD"
PROFILE="AcmeCo-PROD"
REGION="us-west-1"

echo "=== Deploying IAM Deny Policy for PROD SSM Protection ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# Step 1: Discover which role the current SSO session uses
echo "--- Step 1: Discover current IAM role ---"
CALLER_IDENTITY=$(aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" --output json)
echo "$CALLER_IDENTITY" | python3 -m json.tool

ROLE_ARN=$(echo "$CALLER_IDENTITY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Arn'])")
echo "Current identity ARN: $ROLE_ARN"

# Extract role name from ARN (handles both assumed-role and role ARNs)
# SSO assumed role format: arn:aws:sts::<account>:assumed-role/AWSReservedSSO_<PermissionSetName>_<hash>/<email>
ROLE_NAME=$(echo "$ROLE_ARN" | sed -n 's|.*assumed-role/\([^/]*\)/.*|\1|p')
if [[ -z "$ROLE_NAME" ]]; then
  ROLE_NAME=$(echo "$ROLE_ARN" | sed -n 's|.*role/\(.*\)|\1|p')
fi

echo "Role name: $ROLE_NAME"
echo ""

if [[ -z "$ROLE_NAME" ]]; then
  echo "ERROR: Could not determine role name from ARN: $ROLE_ARN"
  echo "You'll need to manually specify the role name."
  echo ""
  echo "To find SSO permission set roles:"
  echo "  aws iam list-roles --profile $PROFILE --region $REGION --query 'Roles[?starts_with(RoleName,\`AWSReservedSSO\`)].RoleName' --output table"
  echo ""
  echo "Then run:"
  echo "  aws iam put-role-policy --role-name <ROLE_NAME> --policy-name $POLICY_NAME --policy-document file://$POLICY_PATH --profile $PROFILE --region $REGION"
  exit 1
fi

# Step 2: Attach the inline deny policy to the role
echo "--- Step 2: Attach deny policy to role '$ROLE_NAME' ---"
echo "Policy source: $POLICY_PATH"
echo ""
echo "Policy content:"
cat "$POLICY_PATH"
echo ""

read -p "Attach policy '$POLICY_NAME' to role '$ROLE_NAME'? (y/N): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo "Aborted. No changes made."
  exit 0
fi

aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://$POLICY_PATH" \
  --profile "$PROFILE" \
  --region "$REGION"

echo "  Policy attached."

echo ""
echo "--- Step 3: Verify policy is attached ---"
aws iam get-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query '{PolicyName:PolicyName,RoleName:RoleName}' \
  --output table

echo ""
echo "=== IAM Deny Policy deployed ==="
echo ""
echo "IMPORTANT NOTES:"
echo "  - This policy uses an inline role policy (not a managed policy)"
echo "  - SSO permission set roles are ephemeral — if the permission set is modified,"
echo "    the inline policy may be removed and need to be reattached"
echo "  - For permanent enforcement, create a managed policy and attach it to the"
echo "    permission set via AWS SSO admin console"
echo "  - The tag-based deny (Statement 1) requires instances to be tagged with"
echo "    Environment=PROD — run deploy-instance-tags.sh first"
echo "  - The instance-specific deny (Statement 2) works immediately as a fallback"
