# Terraform State Management

## Current setup: local state

State is stored in `infra/terraform.tfstate` (gitignored). This is fine for a
single machine managing a single instance — changes are infrequent and the
infrastructure is simple enough to recreate from scratch.

## If you lose the state file

### Option A: Recreate from scratch (simplest)

The infrastructure is fully reproducible. If state is lost:

```bash
# Manually destroy existing resources via AWS console or CLI:
aws lightsail delete-instance --instance-name openclaw
aws lightsail release-static-ip --static-ip-name openclaw-ip
aws iam delete-user --user-name openclaw-agent          # (detach policy first)
aws iam delete-role --role-name openclaw-ssm-hybrid     # (detach policy first)
# Delete the SSM activation from the console

# Then redeploy cleanly:
cd infra && terraform apply
```

The only thing lost is the deploy key at `/root/.ssh/openclaw_deploy` — you will
need to generate a new one and update the GitHub deploy key (takes ~2 minutes).
OpenClaw memory and config live in the `openclaw-memory` GitHub repo and survive.

### Option B: Re-import existing resources into state

If you want to avoid recreating the instance (e.g. to preserve the static IP or
avoid a few minutes of downtime):

```bash
cd infra

# Import each resource by its identifier
terraform import aws_lightsail_instance.openclaw          openclaw
terraform import aws_lightsail_static_ip.openclaw         openclaw-ip
terraform import aws_lightsail_static_ip_attachment.openclaw openclaw-ip
terraform import aws_iam_role.ssm_hybrid                  openclaw-ssm-hybrid
terraform import aws_iam_user.openclaw                    openclaw-agent
terraform import aws_iam_access_key.openclaw              <access-key-id>   # see IAM console
terraform import aws_ssm_activation.openclaw              <activation-id>   # from outputs or SSM console
```

After importing, run `terraform plan` — it should show no changes if the live
resources match the config.

## Protecting the current state file

Back it up manually after significant changes:

```bash
cp infra/terraform.tfstate ~/backups/openclaw-tfstate-$(date +%Y%m%d).json
```

Or keep a copy in an encrypted location (Proton Drive, etc.). Do not commit it
to git — it contains the IAM access key secret in plaintext.

## Future improvement: S3 backend

When you need to run Terraform from a second machine (new laptop, CI/CD), migrate
to an S3 backend. This is a single migration step with no downtime:

### 1. Create the bucket (one-time)

```bash
aws s3api create-bucket \
  --bucket openclaw-tfstate \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

aws s3api put-bucket-versioning \
  --bucket openclaw-tfstate \
  --versioning-configuration Status=Enabled

# Block all public access
aws s3api put-public-access-block \
  --bucket openclaw-tfstate \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

### 2. Add backend block to `infra/main.tf`

```hcl
terraform {
  backend "s3" {
    bucket = "openclaw-tfstate"
    key    = "openclaw/terraform.tfstate"
    region = "eu-west-1"
  }
  required_providers { ... }
}
```

### 3. Migrate local state to S3

```bash
cd infra && terraform init -migrate-state
```

Terraform will copy the local state to S3 and confirm. After that, the local
`terraform.tfstate` file is no longer used and can be deleted.

### What you gain

- Run `terraform plan/apply` from any machine with AWS credentials
- Versioned state — S3 versioning lets you roll back a bad apply
- The S3 bucket costs fractions of a cent per month for a file this small
