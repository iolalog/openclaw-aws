import json
import subprocess

import boto3
import pytest


def _terraform_output() -> dict:
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd="infra",
        capture_output=True,
        text=True,
        check=True,
    )
    raw = json.loads(result.stdout)
    return {k: v["value"] for k, v in raw.items()}


@pytest.fixture(scope="session")
def tf_output():
    return _terraform_output()


@pytest.fixture(scope="session")
def aws_region(tf_output):
    return "eu-west-1"


@pytest.fixture(scope="session")
def ssm_client(aws_region):
    return boto3.client("ssm", region_name=aws_region)


@pytest.fixture(scope="session")
def lightsail_client(aws_region):
    return boto3.client("lightsail", region_name=aws_region)


@pytest.fixture(scope="session")
def iam_client(aws_region):
    return boto3.client("iam", region_name=aws_region)


@pytest.fixture(scope="session")
def managed_instance_id(ssm_client):
    resp = ssm_client.describe_instance_information()
    instances = resp["InstanceInformationList"]
    assert instances, "No managed instances found in SSM — has the bootstrap script run?"
    # Lightsail hybrid activations use mi- prefix
    mi = [i for i in instances if i["InstanceId"].startswith("mi-")]
    assert mi, f"No hybrid-managed instances (mi-*) found; got: {[i['InstanceId'] for i in instances]}"
    return mi[0]["InstanceId"]
