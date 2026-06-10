# 4. Required GitHub Actions secrets

| Secret | Purpose | Required? |
|--------|---------|-----------|
| `AWS_ACCESS_KEY_ID` | AWS credential for the target account | Yes |
| `AWS_SECRET_ACCESS_KEY` | AWS credential for the target account | Yes |
| `AWS_REGION` | e.g. `us-east-1` | Yes |

Everything else (state bucket, DynamoDB lock table, root domain, Cognito
test credentials) is auto-computed at runtime by
`.github/workflows/terraform-test.yml`. AWS account constraints
(instance-type whitelist, EC2 quota, hosted-zone discovery) live in
`ai/testing-guidelines.md`.

---

*Source detail for `AGENTS.md`. The summary in AGENTS.md is authoritative for scope; this file holds the full text.*
