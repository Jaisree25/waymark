# infra — Terraform for all GCP resources (Person C)

Everything cloud is code — no click-ops. From `docs/M1/03-backend-gcp.md` §7.

```bash
cd envs/dev
terraform init
terraform validate   # CI gate
terraform plan       # CI gate — shows expected resource set
terraform apply
```

`db_password` and `database_url` come from **Secret Manager** / `TF_VAR_*`, never committed tfvars.
`modules/` is where reusable resource groups go as this grows; `envs/{dev,prod}/` wire them per env.
