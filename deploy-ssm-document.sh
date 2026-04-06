#!/bin/bash
# deploy-ssm-document.sh
# Registers both SSM documents in your PROD account:
#   1. AcmeCo-SafeRunShellScript — blocks ALL execution on PROD, allows UAT
#   2. AcmeCo-ProdDiagnostics    — PROD-only read-only diagnostics with command blocklist
#
# PROD validation tests are intentionally excluded from this script.
# Run them during off-hours: bash test-prod-safeguards.sh
#
# BEFORE RUNNING: Update PROFILE and REGION to match your environment.
#
# Run with: bash deploy-ssm-document.sh

set -euo pipefail

PROFILE="AcmeCo-PROD"
REGION="us-west-1"

DOC1_PATH="./ssm-safe-run-shell-script.yaml"
DOC1_NAME="AcmeCo-SafeRunShellScript"

DOC2_PATH="./ssm-prod-diagnostics.yaml"
DOC2_NAME="AcmeCo-ProdDiagnostics"

# --- Helper: register or update a document ---
register_document() {
  local DOC_NAME="$1"
  local DOC_PATH="$2"

  echo "--- Registering: $DOC_NAME ---"
  echo "Source: $DOC_PATH"

  if aws ssm describe-document --name "$DOC_NAME" --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1; then
    echo "Document already exists. Deleting and recreating..."
    aws ssm delete-document \
      --name "$DOC_NAME" \
      --profile "$PROFILE" \
      --region "$REGION" > /dev/null
    echo "  Deleted. Waiting 5s for propagation..."
    sleep 5
    aws ssm create-document \
      --name "$DOC_NAME" \
      --content "file://$DOC_PATH" \
      --document-type Command \
      --document-format YAML \
      --profile "$PROFILE" \
      --region "$REGION" > /dev/null
    echo "  Recreated."
  else
    echo "Creating new document..."
    aws ssm create-document \
      --name "$DOC_NAME" \
      --content "file://$DOC_PATH" \
      --document-type Command \
      --document-format YAML \
      --profile "$PROFILE" \
      --region "$REGION" > /dev/null
    echo "  Created."
  fi

  aws ssm describe-document \
    --name "$DOC_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'Document.{Name:Name,Status:Status,Version:DocumentVersion,Schema:SchemaVersion}' \
    --output table
  echo ""
}

# --- Helper: run a single test ---
run_test() {
  local TEST_LABEL="$1"
  local DOC_NAME="$2"
  local INSTANCE_ID="$3"
  local COMMANDS="$4"
  local EXPECT_STATUS="$5"
  local COMMENT="$6"
  local RESULT_VAR="$7"

  echo "Sending: $COMMANDS"
  echo "Via: $DOC_NAME → $INSTANCE_ID  (expect: $EXPECT_STATUS)"

  # StringList docs (SafeRunShellScript) need commands=["..."]
  # String docs (ProdDiagnostics) need commands="..."
  if [[ "$DOC_NAME" == "$DOC2_NAME" ]]; then
    PARAMS="commands=$COMMANDS"
  else
    PARAMS="commands=[\"$COMMANDS\"]"
  fi

  CMD_ID=$(aws ssm send-command \
    --document-name "$DOC_NAME" \
    --instance-ids "$INSTANCE_ID" \
    --parameters "$PARAMS" \
    --comment "$COMMENT" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'Command.CommandId' \
    --output text)

  echo "Command ID: $CMD_ID  — waiting 15s..."
  sleep 15

  ACTUAL=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'Status' \
    --output text 2>/dev/null || echo "PENDING")

  if [[ "$ACTUAL" == "$EXPECT_STATUS" ]]; then
    echo "Result: PASS (status: $ACTUAL)"
    eval "${RESULT_VAR}=PASS"
  else
    echo "Result: FAIL (expected $EXPECT_STATUS, got $ACTUAL)"
    eval "${RESULT_VAR}=FAIL"
  fi
  echo ""
}

# ============================================================
echo "========================================================"
echo "=== SSM Document Registration                        ==="
echo "========================================================"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

register_document "$DOC1_NAME" "$DOC1_PATH"
register_document "$DOC2_NAME" "$DOC2_PATH"

# ============================================================
echo "========================================================"
echo "=== UAT Smoke Tests (safe to run during business hrs) ==="
echo "========================================================"
echo ""

echo "--- T1: SafeRunShellScript on UAT2 — should be ALLOWED ---"
run_test "T1" "$DOC1_NAME" "i-0a1b2c3d4e5f60003" \
  "hostname" "Success" "SafeRunShell UAT allow test" "T1"

echo "--- T2: ProdDiagnostics on UAT2 — should be BLOCKED (wrong env) ---"
run_test "T2" "$DOC2_NAME" "i-0a1b2c3d4e5f60003" \
  "hostname" "Failed" "ProdDiag UAT reject test" "T2"

# ============================================================
echo "========================================================"
echo "=== UAT Test Summary                                 ==="
echo "========================================================"
echo ""
printf "%-5s  %-32s  %-25s  %-10s  %s\n" \
  "Test" "Description" "Instance" "Expected" "Result"
printf "%-5s  %-32s  %-25s  %-10s  %s\n" \
  "-----" "--------------------------------" "-------------------------" "----------" "------"
printf "%-5s  %-32s  %-25s  %-10s  %s\n" \
  "T1" "SafeRunShell: UAT allowed" "i-0a1b2c3d4e5f60003" "ALLOWED" "$T1"
printf "%-5s  %-32s  %-25s  %-10s  %s\n" \
  "T2" "ProdDiag: UAT rejected" "i-0a1b2c3d4e5f60003" "BLOCKED" "$T2"
echo ""

if [[ "$T1" == "PASS" && "$T2" == "PASS" ]]; then
  echo "UAT TESTS PASSED — documents registered and UAT behaviour confirmed."
else
  echo "WARNING: One or more UAT tests failed. Review output above before proceeding."
fi

echo ""
echo "=== Registration complete ==="
echo ""
echo "NOTE: PROD validation tests (SafeRunShell block + ProdDiag allow/block)"
echo "      are intentionally deferred to off-hours."
echo "      Run when ready: bash test-prod-safeguards.sh"
