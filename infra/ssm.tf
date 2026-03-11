resource "aws_ssm_document" "openclaw_recover" {
  name            = "OpenClawRecover"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Restore OpenClaw gateway from a known-good or safe config backup and restart the service."
    parameters = {
      Mode = {
        type          = "String"
        description   = "Which backup to restore: 'known-good' (last healthy state) or 'safe' (bootstrap factory config)."
        default       = "known-good"
        allowedValues = ["known-good", "safe"]
      }
    }
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "RecoverOpenClaw"
        inputs = {
          runCommand = ["/usr/local/bin/openclaw-recover {{ Mode }}"]
        }
      }
    ]
  })
}

resource "aws_ssm_document" "openclaw_status" {
  name            = "OpenClawStatus"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Show OpenClaw gateway status: service state, fail counter, config file inventory, recent logs."
    parameters    = {}
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "StatusOpenClaw"
        inputs = {
          runCommand = ["/usr/local/bin/openclaw-status"]
        }
      }
    ]
  })
}
