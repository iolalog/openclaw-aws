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
aws ec2 terminate-instances --instance-ids i-XXXXXXXXXXXXXXXXX
aws ec2 release-address --allocation-id eipalloc-XXXXXXXXXXXXXXXXX
aws ec2 delete-security-group --group-id sg-XXXXXXXXXXXXXXXXX
aws ec2 delete-subnet --subnet-id subnet-XXXXXXXXXXXXXXXXX
aws ec2 delete-route-table --route-table-id rtb-XXXXXXXXXXXXXXXXX
aws ec2 detach-internet-gateway --internet-gateway-id igw-XXXXXXXXXXXXXXXXX --vpc-id vpc-XXXXXXXXXXXXXXXXX
aws ec2 delete-internet-gateway --internet-gateway-id igw-XXXXXXXXXXXXXXXXX
aws ec2 delete-vpc --vpc-id vpc-XXXXXXXXXXXXXXXXX
aws iam remove-role-from-instance-profile --instance-profile-name openclaw-instance-profile --role-name openclaw-instance-role
aws iam delete-instance-profile --instance-profile-name openclaw-instance-profile
aws iam detach-role-policy --role-name openclaw-instance-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role-policy --role-name openclaw-instance-role --policy-name openclaw-cost-explorer
aws iam delete-role --role-name openclaw-instance-role
# Delete the DLM lifecycle policy and dlm role from the console or CLI

# Then redeploy cleanly:
cd infra && terraform apply
```

The only things lost are the SSH deploy keys at `/root/.ssh/openclaw_deploy` and
`/root/.ssh/openclaw_infra` — you will need to generate new ones and update the
GitHub deploy keys (takes ~2 minutes). OpenClaw memory and config live in the
`openclaw-memory` GitHub repo and survive.

### Option B: Re-import existing resources into state

If you want to avoid recreating the instance (e.g. to preserve the EIP or
avoid a few minutes of downtime):

```bash
cd infra

# Get resource IDs from the AWS console or CLI first, then:
terraform import aws_vpc.openclaw                    vpc-XXXXXXXXXXXXXXXXX
terraform import aws_subnet.openclaw                 subnet-XXXXXXXXXXXXXXXXX
terraform import aws_internet_gateway.openclaw       igw-XXXXXXXXXXXXXXXXX
terraform import aws_route_table.openclaw            rtb-XXXXXXXXXXXXXXXXX
terraform import aws_security_group.openclaw         sg-XXXXXXXXXXXXXXXXX
terraform import aws_iam_role.openclaw               openclaw-instance-role
terraform import aws_iam_instance_profile.openclaw   openclaw-instance-profile
terraform import aws_instance.openclaw               i-XXXXXXXXXXXXXXXXX
terraform import aws_eip.openclaw                    eipalloc-XXXXXXXXXXXXXXXXX
```

After importing, run `terraform plan` — it should show no changes if the live
resources match the config.

## Protecting the current state file

Back it up manually after significant changes:

```bash
cp infra/terraform.tfstate ~/backups/openclaw-tfstate-$(date +%Y%m%d).json
```

Or keep a copy in an encrypted location (Proton Drive, etc.). Do not commit it
to git.

## Future improvement: S3 backend

When you need to run Terraform from a second machine (new laptop, CI/CD), migrate
to an S3 backend. This is a single migration step with no downtime:

### 1. Create the bucket (one-time)

```bash
aws s3api create-bucket \
  --bucket openclaw-tfstate \
  --region eu-north-1 \
  --create-bucket-configuration LocationConstraint=eu-north-1

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
    region = "eu-north-1"
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
