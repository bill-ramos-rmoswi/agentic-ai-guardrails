#!/bin/bash
# test-prod-safeguards.sh
# Off-hours PROD validation tests for both SSM documents.
# Run after business hours to avoid impact during peak usage.
#
# Tests:
#   T1 — SafeRunShellScript blocks PROD completely
#   T2 — ProdDiagnostics allows safe read-only command (hostname)
#   T3 — ProdDiagnostics allows tail on a log file
#   T4 — ProdDiagnostics blocks bench restart
#   T5 — ProdDiagnostics blocks git checkout
#   T6 — ProdDiagnostics blocks output redirection (echo > file)
#
# Prerequisites:
#   - deploy-ssm-document.sh must have been run first
#   - SSO session active: aws sso login --profile AcmeCo-PROD
#
# BEFORE RUNNING: Update PROFILE, REGION, and PROD_INSTANCE to match your environment.
#
# Run with: bash test-prod-safeguards.sh

set -euo pipefail

PROFILE="AcmeCo-PROD"
REGION="us-west-1"
PROD_INSTANCE="i-0a1b2c3d4e5f60001"
DOC1_NAME="AcmeCo-SafeRunShellScript"
DOC2_NAME="AcmeCo-ProdDiagnostics"

# --- Helper: run a single test and fetch step output ---
run_test() {
  local TEST_LABEL="$1"
  local DOC_NAME="$2"
  local INSTANCE_ID="$3"
  local COMMANDS="$4"
  local EXPECT_STATUS="$5"
  local COMMENT="$6"
  local STEP_NAME="$7"
  local RESULT_VAR="$8"

  echo "Sending: $COMMANDS"
  echo "Via: $DOC_NAME → $INSTANCE_ID  (expect: $EXPECT_STATUS)"

  # SafeRunShellScript uses StringList: commands=["..."]
  # ProdDiagnostics uses String: commands="..."
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

  STEP_OUT=$(aws ssm get-command-invocation \
    --command-id "$CMD_ID" \
    --instance-id "$INSTANCE_ID" \
    --plugin-name "$STEP_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null || echo "")

  if [[ -n "$STEP_OUT" && "$STEP_OUT" != "None" ]]; then
    echo "Step output ($STEP_NAME):"
    echo "$STEP_OUT" | tail -5 | sed 's/^/  /'
  fi

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
echo "=== PROD Safeguard Validation Tests — Off-Hours     ==="
echo "========================================================"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "PROD Instance: $PROD_INSTANCE"
echo ""

# ============================================================
echo "========================================================"
echo "=== Section 1: SafeRunShellScript blocks PROD        ==="
echo "========================================================"
echo ""

echo "--- T1: hostname via SafeRunShellScript on PROD — should be BLOCKED ---"
run_test "T1" "$DOC1_NAME" "$PROD_INSTANCE" \
  "hostname" "Failed" \
  "SafeRunShell PROD block test" \
  "ValidateEnvironment" "T1"

# ============================================================
echo "========================================================"
echo "=== Section 2: ProdDiagnostics allows read-only cmds ==="
echo "========================================================"
echo ""

echo "--- T2: hostname via ProdDiagnostics on PROD — should be ALLOWED ---"
run_test "T2" "$DOC2_NAME" "$PROD_INSTANCE" \
  "hostname" "Success" \
  "ProdDiag hostname test" \
  "ExecuteDiagnostics" "T2"

echo "--- T3: tail /var/log/syslog via ProdDiagnostics on PROD — should be ALLOWED ---"
run_test "T3" "$DOC2_NAME" "$PROD_INSTANCE" \
  "tail -5 /var/log/syslog" "Success" \
  "ProdDiag tail log test" \
  "ExecuteDiagnostics" "T3"

# ============================================================
echo "========================================================"
echo "=== Section 3: ProdDiagnostics blocks write commands  ==="
echo "========================================================"
echo ""

echo "--- T4: bench restart via ProdDiagnostics on PROD — should be BLOCKED ---"
run_test "T4" "$DOC2_NAME" "$PROD_INSTANCE" \
  "bench restart" "Failed" \
  "ProdDiag bench restart block test" \
  "ValidateCommandsSafe" "T4"

echo "--- T5: git checkout main via ProdDiagnostics on PROD — should be BLOCKED ---"
run_test "T5" "$DOC2_NAME" "$PROD_INSTANCE" \
  "git checkout main" "Failed" \
  "ProdDiag git checkout block test" \
  "ValidateCommandsSafe" "T5"

echo "--- T6: echo redirection via ProdDiagnostics on PROD — should be BLOCKED ---"
run_test "T6" "$DOC2_NAME" "$PROD_INSTANCE" \
  "echo test > /tmp/safeguard-test.txt" "Failed" \
  "ProdDiag output redirect block test" \
  "ValidateCommandsSafe" "T6"

# ============================================================
echo "========================================================"
echo "=== Final Test Summary                               ==="
echo "========================================================"
echo ""
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "Test" "Description" "Document" "Expected" "Result"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "-----" "--------------------------------------" "----------------------" "----------" "------"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "T1" "SafeRunShell: PROD fully blocked" "SafeRunShellScript" "BLOCKED" "$T1"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "T2" "ProdDiag: hostname allowed" "ProdDiagnostics" "ALLOWED" "$T2"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "T3" "ProdDiag: tail log allowed" "ProdDiagnostics" "ALLOWED" "$T3"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "T4" "ProdDiag: bench restart blocked" "ProdDiagnostics" "BLOCKED" "$T4"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "T5" "ProdDiag: git checkout blocked" "ProdDiagnostics" "BLOCKED" "$T5"
printf "%-5s  %-38s  %-22s  %-10s  %s\n" \
  "T6" "ProdDiag: output redirect blocked" "ProdDiagnostics" "BLOCKED" "$T6"
echo ""

PASS_COUNT=0; FAIL_COUNT=0
for T in "$T1" "$T2" "$T3" "$T4" "$T5" "$T6"; do
  [[ "$T" == "PASS" ]] && ((PASS_COUNT++)) || ((FAIL_COUNT++))
done

echo "$PASS_COUNT/6 tests passed, $FAIL_COUNT failed"
echo ""
if [[ "$FAIL_COUNT" -eq 0 ]]; then
  echo "ALL TESTS PASSED — PROD safeguards are working correctly."
else
  echo "WARNING: $FAIL_COUNT test(s) failed. Review output above."
fi
