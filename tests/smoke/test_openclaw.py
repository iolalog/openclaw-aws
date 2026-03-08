"""
Smoke tests for the OpenClaw Lightsail deployment.

Run after `terraform apply` completes and the bootstrap script has had ~2 min:

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
    def test_port_22_closed(self, lightsail_client):
        resp = lightsail_client.get_instance_port_states(instanceName="openclaw")
        port_states = resp["portStates"]
        open_ports = {p["fromPort"] for p in port_states if p["state"] == "open"}
        assert 22 not in open_ports, (
            f"Port 22 is open — it must remain closed. Open ports: {open_ports}"
        )

    def test_port_443_open(self, lightsail_client):
        resp = lightsail_client.get_instance_port_states(instanceName="openclaw")
        port_states = resp["portStates"]
        open_ports = {p["fromPort"] for p in port_states if p["state"] == "open"}
        assert 443 in open_ports, f"Port 443 is not open. Open ports: {open_ports}"


class TestIAMScope:
    """Verify the openclaw-agent IAM user cannot exceed its minimal policy."""

    def test_cannot_list_s3_buckets(self, iam_client):
        """openclaw-agent has no S3 permissions — simulate with a policy check."""
        # We verify the inline policy contains only ce:* actions
        resp = iam_client.get_user_policy(
            UserName="openclaw-agent",
            PolicyName="openclaw_minimal",
        )
        import json
        from urllib.parse import unquote
        policy = json.loads(unquote(resp["PolicyDocument"]))
        actions = []
        for stmt in policy["Statement"]:
            acts = stmt["Action"]
            if isinstance(acts, str):
                acts = [acts]
            actions.extend(acts)
        assert all(a.startswith("ce:") for a in actions), (
            f"Unexpected actions in openclaw-agent policy: {actions}"
        )
