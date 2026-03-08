# SSM hybrid activation — Lightsail instances cannot use IAM instance profiles
resource "aws_iam_role" "ssm_hybrid" {
  name = "openclaw-ssm-hybrid"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_hybrid.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_ssm_activation" "openclaw" {
  name               = "openclaw-activation"
  iam_role           = aws_iam_role.ssm_hybrid.name
  registration_limit = 1

  depends_on = [aws_iam_role_policy_attachment.ssm_core]
}

# Scoped IAM user for OpenClaw skills — expand deliberately as skills are added
resource "aws_iam_user" "openclaw" {
  name = "openclaw-agent"
}

resource "aws_iam_user_policy" "openclaw_minimal" {
  user = aws_iam_user.openclaw.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ce:Get*", "ce:Describe*", "ce:List*"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_access_key" "openclaw" {
  user = aws_iam_user.openclaw.name
}
