# Used only by infra-apply-emulated.yml. Everything that points at the emulator
# lives in this one file and behind the `emulator.enabled` flag, so no endpoint
# override can leak into a production plan by accident.

environment = "emulated"

# 000000000000 is the emulator's fixed account id. It is also a Gitleaks-safe
# placeholder — it is not a real AWS account.
region = "us-east-1"

# The emulator does not implement multi-AZ NAT or three-zone spread, and the
# runner has neither the memory nor the time for it.
availability_zone_count = 2

node_group = {
  instance_types = ["t3.small"]
  desired_size   = 1
  min_size       = 1
  max_size       = 2
}

log_retention_days = 1

emulator = {
  enabled      = true
  endpoint_url = "http://localhost:4566"
  access_key   = "test"
  secret_key   = "test"
}
