#!/bin/bash
# deploy-instance-tags.sh
# Tags EC2 instances with Environment values for PROD safeguards.
#
# BEFORE RUNNING: Replace the instance IDs and profile names below
# with values from your own environment.
#
# Run with: bash deploy-instance-tags.sh

set -euo pipefail

echo "=== Tagging EC2 Instances with Environment Tags ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# PROD instance (us-west-1, primary account)
echo "Tagging i-0a1b2c3d4e5f60001 (MyApp-PROD) as Environment=PROD..."
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60001 \
  --tags Key=Environment,Value=PROD \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "  Done."

# Legacy UAT instance (us-west-1, primary account — still in use until new UAT declared ready)
echo "Tagging i-0a1b2c3d4e5f60002 (MyApp-UAT-legacy) as Environment=UAT..."
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60002 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "  Done."

# UAT2 instance (us-west-1, primary account)
echo "Tagging i-0a1b2c3d4e5f60003 (MyApp-UAT2) as Environment=UAT..."
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60003 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "  Done."

# UAT3 instance (us-west-1, primary account)
echo "Tagging i-0a1b2c3d4e5f60004 (MyApp-UAT3) as Environment=UAT..."
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60004 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-PROD \
  --region us-west-1

echo "  Done."

# UAT instance in separate UAT account (us-west-2)
echo "Tagging i-0a1b2c3d4e5f60005 (MyApp-UAT) as Environment=UAT..."
aws ec2 create-tags \
  --resources i-0a1b2c3d4e5f60005 \
  --tags Key=Environment,Value=UAT \
  --profile AcmeCo-UAT \
  --region us-west-2

echo "  Done."

echo ""
echo "=== Verification ==="
echo ""

# Collect tag values for each instance
TAG_PROD=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=i-0a1b2c3d4e5f60001" "Name=key,Values=Environment" \
  --profile AcmeCo-PROD \
  --region us-west-1 \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "FAILED")

TAG_UAT_LEGACY=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=i-0a1b2c3d4e5f60002" "Name=key,Values=Environment" \
  --profile AcmeCo-PROD \
  --region us-west-1 \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "FAILED")

TAG_UAT2=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=i-0a1b2c3d4e5f60003" "Name=key,Values=Environment" \
  --profile AcmeCo-PROD \
  --region us-west-1 \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "FAILED")

TAG_UAT3=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=i-0a1b2c3d4e5f60004" "Name=key,Values=Environment" \
  --profile AcmeCo-PROD \
  --region us-west-1 \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "FAILED")

TAG_UAT=$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=i-0a1b2c3d4e5f60005" "Name=key,Values=Environment" \
  --profile AcmeCo-UAT \
  --region us-west-2 \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "FAILED")

# Print consolidated table
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "Status" "Instance ID" "Name" "Region" "Environment" "Profile"
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "--------" "-------------------------" "--------------------" "-----------" "---------------" "---------------"

# PROD row
if [[ "$TAG_PROD" == "PROD" ]]; then STATUS="OK"; else STATUS="FAILED"; fi
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "$STATUS" "i-0a1b2c3d4e5f60001" "MyApp-PROD" "us-west-1" "$TAG_PROD" "AcmeCo-PROD"

# UAT legacy row
if [[ "$TAG_UAT_LEGACY" == "UAT" ]]; then STATUS="OK"; else STATUS="FAILED"; fi
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "$STATUS" "i-0a1b2c3d4e5f60002" "MyApp-UAT-legacy" "us-west-1" "$TAG_UAT_LEGACY" "AcmeCo-PROD"

# UAT2 row
if [[ "$TAG_UAT2" == "UAT" ]]; then STATUS="OK"; else STATUS="FAILED"; fi
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "$STATUS" "i-0a1b2c3d4e5f60003" "MyApp-UAT2" "us-west-1" "$TAG_UAT2" "AcmeCo-PROD"

# UAT3 row
if [[ "$TAG_UAT3" == "UAT" ]]; then STATUS="OK"; else STATUS="FAILED"; fi
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "$STATUS" "i-0a1b2c3d4e5f60004" "MyApp-UAT3" "us-west-1" "$TAG_UAT3" "AcmeCo-PROD"

# UAT account row
if [[ "$TAG_UAT" == "UAT" ]]; then STATUS="OK"; else STATUS="FAILED"; fi
printf "%-8s  %-25s  %-20s  %-11s  %-15s  %s\n" \
  "$STATUS" "i-0a1b2c3d4e5f60005" "MyApp-UAT" "us-west-2" "$TAG_UAT" "AcmeCo-UAT"

echo ""
echo "=== All instances tagged. ==="
