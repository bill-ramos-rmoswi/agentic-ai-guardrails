# create-github-repo.ps1
# Run this script from inside the agentic-ai-guardrails folder.
# Prerequisites: gh CLI authenticated, git installed.
#
# Usage:
#   cd C:\path\to\agentic-ai-guardrails
#   .\create-github-repo.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoName    = "agentic-ai-guardrails"
$Description = "Guardrail patterns for giving AI agents safe access to AWS infrastructure — companion repo for the Hitchhiker's Guide to Agentic AI in Production blog post."
$Visibility  = "public"   # change to "private" if you prefer

Write-Host ""
Write-Host "=== Creating GitHub repo: $RepoName ===" -ForegroundColor Cyan
Write-Host "Timestamp: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)"
Write-Host ""

# 1. Verify we're in the right folder
$ExpectedFiles = @("README.md", "deploy-instance-tags.sh", "iam-deny-ssm-prod.json")
foreach ($f in $ExpectedFiles) {
    if (-not (Test-Path $f)) {
        Write-Error "Expected file '$f' not found. Run this script from inside the agentic-ai-guardrails folder."
        exit 1
    }
}
Write-Host "Working directory: $(Get-Location)" -ForegroundColor Green
Write-Host ""

# 2. Create the GitHub repo
Write-Host "--- Step 1: Creating GitHub repo ---" -ForegroundColor Yellow
gh repo create $RepoName `
    --description $Description `
    --$Visibility `
    --confirm 2>$null

if ($LASTEXITCODE -ne 0) {
    # Repo may already exist — continue
    Write-Host "Note: repo may already exist, continuing..." -ForegroundColor Yellow
}

# Get the authenticated username for the remote URL
$GitHubUser = gh api user --jq '.login'
$RemoteUrl  = "https://github.com/$GitHubUser/$RepoName.git"
Write-Host "Repo URL: $RemoteUrl" -ForegroundColor Green
Write-Host ""

# 3. Initialize git and set up remote
Write-Host "--- Step 2: Initializing git ---" -ForegroundColor Yellow

if (-not (Test-Path ".git")) {
    git init
    git branch -M main
} else {
    Write-Host "Git repo already initialized." -ForegroundColor Gray
}

# Add or update remote
$RemoteExists = git remote | Where-Object { $_ -eq "origin" }
if ($RemoteExists) {
    git remote set-url origin $RemoteUrl
    Write-Host "Updated remote origin to $RemoteUrl" -ForegroundColor Gray
} else {
    git remote add origin $RemoteUrl
    Write-Host "Added remote origin: $RemoteUrl" -ForegroundColor Gray
}
Write-Host ""

# 4. Configure git identity if not already set
$GitName  = git config --global user.name  2>$null
$GitEmail = git config --global user.email 2>$null
if (-not $GitName -or -not $GitEmail) {
    Write-Host "--- Setting git identity from gh profile ---" -ForegroundColor Yellow
    $GhEmail = gh api user/emails --jq '.[0].email' 2>$null
    if ($GhEmail) { git config --global user.email $GhEmail }
    if (-not $GitName) { git config --global user.name $GitHubUser }
}

# 5. Stage, commit, push
Write-Host "--- Step 3: Committing files ---" -ForegroundColor Yellow
git add README.md
git add deploy-instance-tags.sh
git add deploy-iam-deny-policy.sh
git add deploy-ssm-document.sh
git add iam-deny-ssm-prod.json
git add ssm-safe-run-shell-script.yaml
git add ssm-prod-diagnostics.yaml
git add test-prod-safeguards.sh

git status

Write-Host ""
Write-Host "--- Step 4: Creating initial commit ---" -ForegroundColor Yellow
git commit -m "Initial commit: agentic AI guardrail patterns for AWS

Three-layer guardrail model for giving AI agents safe access to AWS
infrastructure: EC2 environment tags, IAM deny policies, and custom
SSM execution documents that enforce PROD/UAT boundaries at runtime.

Companion repo for: The Hitchhiker's Guide to Agentic AI in Production"

Write-Host ""
Write-Host "--- Step 5: Pushing to GitHub ---" -ForegroundColor Yellow
git push -u origin main

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Repo live at: https://github.com/$GitHubUser/$RepoName" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Visit the repo URL above and confirm the files look right"
Write-Host "  2. Add the repo link to the blog post Appendix section"
Write-Host "  3. Consider adding a GitHub topic tag: 'aws', 'agentic-ai', 'ssm', 'guardrails'"
