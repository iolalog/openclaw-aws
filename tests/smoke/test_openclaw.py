"""
Smoke tests for the OpenClaw EC2 deployment.

Run after `terraform apply` completes and the bootstrap script has had ~3 min:

    uv run pytest tests/smoke/ -v
"""

import boto3
import pytest


class TestSSM:
    def test_instance_online(self, ssm_client, managed_instance_id):
        resp = ssm_client.describe_instance_information(
            Filters=[{"Key": "InstanceIds", "Values": [managed_instance_id]}]
        )
        instances = resp["InstanceInformationList"]
        assert instances, f"Instance {managed_instance_id} not found in SSM"
        assert instances[0]["PingStatus"] == "Online", (
            f"Expected Online, got {instances[0]['PingStatus']}"
        )

    def test_openclaw_service_active(self, ssm_client, managed_instance_id):
        resp = ssm_client.send_command(
            InstanceIds=[managed_instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": ["systemctl is-active openclaw-gateway"]},
        )
        command_id = resp["Command"]["CommandId"]

        import time
        for _ in range(12):
            time.sleep(5)
            result = ssm_client.get_command_invocation(
                CommandId=command_id,
                InstanceId=managed_instance_id,
            )
            if result["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
                break

        assert result["Status"] == "Success", (
            f"Command status: {result['Status']}\n"
            f"stdout: {result.get('StandardOutputContent')}\n"
            f"stderr: {result.get('StandardErrorContent')}"
        )
        assert result["StandardOutputContent"].strip() == "active", (
            f"openclaw-gateway is not active: {result['StandardOutputContent'].strip()}"
        )


class TestFirewall:
    def test_no_inbound_rules(self, ec2_client):
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": ["openclaw-sg"]}]
        )
        sgs = resp["SecurityGroups"]
        assert sgs, "Security group 'openclaw-sg' not found"
        sg = sgs[0]
        assert sg["IpPermissions"] == [], (
            f"Security group has inbound rules — expected none: {sg['IpPermissions']}"
        )

    def test_port_22_not_reachable(self, ec2_client):
        resp = ec2_client.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": ["openclaw-sg"]}]
        )
        sg = resp["SecurityGroups"][0]
        open_ports = set()
        for rule in sg["IpPermissions"]:
            if rule.get("FromPort") is not None:
                open_ports.add(rule["FromPort"])
        assert 22 not in open_ports, (
            f"Port 22 is open in security group — it must remain closed"
        )


class TestIAMScope:
    """Verify the openclaw instance role cannot exceed its minimal policy."""

    def test_role_policy_ce_only(self, iam_client):
        """Instance role inline policy contains only ce:* actions."""
        import json
        resp = iam_client.get_role_policy(
            RoleName="openclaw-instance-role",
            PolicyName="openclaw-cost-explorer",
        )
        from urllib.parse import unquote
        policy = json.loads(unquote(resp["PolicyDocument"]))
        actions = []
        for stmt in policy["Statement"]:
            acts = stmt["Action"]
            if isinstance(acts, str):
                acts = [acts]
            actions.extend(acts)
        assert all(a.startswith("ce:") for a in actions), (
            f"Unexpected actions in openclaw instance role policy: {actions}"
        )
