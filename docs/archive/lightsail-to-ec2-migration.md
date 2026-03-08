# Lightsail → EC2 Migration (one-time)

> This is a one-time migration guide for moving from the original Lightsail deployment
> to the current EC2 setup. Not relevant for fresh EC2 installs — see `docs/setup.md`.

## Why migrate

| Problem (Lightsail) | Solution (EC2) |
|---|---|
| No IAM instance profiles → long-lived access keys on disk | EC2 instance role → auto-rotating credentials via IMDS |
| SSM required hybrid activation workaround | SSM works natively with instance profile |
| 1GB RAM → heap tuning + swap required | t4g.small 2GB RAM → no tuning needed |

## Strategy: backup state, fresh apply, AWS CLI cleanup

Rather than a complex blue-green Terraform cutover:
1. Stop the Lightsail service (disconnect from Slack/OpenRouter)
2. Back up and clear the Lightsail Terraform state
3. Run a vanilla `terraform apply` — identical to a fresh EC2 install
4. Verify EC2 is working
5. Destroy the Lightsail instance with AWS CLI commands

The Lightsail instance stays reachable via SSM throughout in case you need to check anything.

## Steps

### 1. Stop Lightsail service

Disconnect from Slack and OpenRouter before the new instance is up.

```bash
aws ssm send-command \
  --instance-id mi-XXXXXXXXXXXXXXXXX \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl stop openclaw-gateway"]}' \
  --region eu-north-1 \
  --query 'Command.CommandId' --output text
```

### 2. Back up and clear Terraform state

```bash
cp infra/terraform.tfstate ~/backups/lightsail-tfstate-$(date +%Y%m%d).json
mv infra/terraform.tfstate ~/backups/lightsail-tfstate-active.json
```

Terraform now has no knowledge of the old Lightsail resources. They continue running
untouched — Terraform simply won't manage them anymore.

### 3. Run fresh EC2 setup

Follow `docs/setup.md` from the top exactly as if this were a new installation.
The memory repo on GitHub survives — bootstrap will clone it once you add the new deploy key.

### 4. Verify EC2 is working

```bash
uv run pytest tests/smoke/ -v
```

Send a DM to the bot and confirm it responds.

### 5. Destroy Lightsail (AWS CLI — no Terraform needed)

```bash
# Delete the instance (takes ~1 min)
aws lightsail delete-instance --instance-name openclaw --region eu-north-1

# Release the static IP
aws lightsail release-static-ip --static-ip-name openclaw-ip --region eu-north-1

# Delete the IAM user
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
KEY_ID=$(aws iam list-access-keys --user-name openclaw-agent --query 'AccessKeyMetadata[0].AccessKeyId' --output text)
aws iam delete-access-key --user-name openclaw-agent --access-key-id "$KEY_ID"
aws iam delete-user-policy --user-name openclaw-agent --policy-name openclaw_minimal
aws iam delete-user --user-name openclaw-agent

# Delete the SSM hybrid role
aws iam detach-role-policy --role-name openclaw-ssm-hybrid \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam delete-role --role-name openclaw-ssm-hybrid
```

### 6. Remove old GitHub deploy keys

In GitHub, remove the old Lightsail deploy keys from:
- `YOUR_USERNAME/openclaw-memory` → Settings → Deploy keys
- `YOUR_USERNAME/openclaw-aws` → Settings → Deploy keys

The new EC2 keys were added during step 3.
