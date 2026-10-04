# vibratio-infra

Terraform for the vibratio MVP on AWS.

vibratio runs a batch once a day for a single user, so the infrastructure is fully serverless and has no always-on resources. Terraform is the source of truth for the infrastructure; this README only records design decisions and how to operate it.

## Architecture

```text
EventBridge Scheduler (daily, Asia/Tokyo)
    ↓
Batch Lambda ──→ SSM Parameter Store (LLM / TTS / Discord credentials)
    │   │   └──→ Discord (audio URL)
    │   └──→ S3 data bucket (articles / episodes / audio) ──→ CloudFront (audio/ only) ← audio.vibratio.cl17.dev
    ↓
DynamoDB config table (Sources, ...)
    ↑
AppSync GraphQL API (JS resolvers) ← api.vibratio.cl17.dev ←── Cognito User Pool (sign-in)
    ↑
CMS (Vite + React) ←── CloudFront ← cms.vibratio.cl17.dev ←── S3 CMS bucket
```

The batch collects articles, generates the script and the audio with external AI APIs, stores them in S3 and posts the audio URL to Discord. The URL points to a CloudFront distribution that exposes only `audio/`. The CMS only edits settings, which AppSync reads and writes in DynamoDB without any Lambda function in between.

All logs go to CloudWatch Logs with a fixed retention period.

Every public endpoint has a custom domain under `vibratio.cl17.dev`, whose DNS is hosted on Cloudflare:

| Domain | Target |
| --- | --- |
| `cms.vibratio.cl17.dev` | CMS CloudFront distribution |
| `audio.vibratio.cl17.dev` | Audio CloudFront distribution |
| `api.vibratio.cl17.dev` | AppSync custom domain (`https://api.vibratio.cl17.dev/graphql`) |

## Directory Layout

```text
scripts/
└── test-resolvers.sh  # Runs the resolver tests with `aws appsync evaluate-code`
terraform/
├── .tflint.hcl        # TFLint rulesets (terraform recommended, AWS)
├── versions.tf        # Terraform/provider versions, S3 backend, provider config (incl. us-east-1 alias)
├── variables.tf       # Tunable settings (region, schedule, retention, ...)
├── main.tf            # Shared data sources and the Lambda placeholder package
├── storage.tf         # S3 data bucket and its key prefixes
├── config.tf          # DynamoDB table for settings edited from the CMS
├── secrets.tf         # SSM SecureString parameters for external APIs
├── batch.tf           # Batch Lambda, EventBridge Scheduler, related IAM
├── api.tf             # AppSync API, custom domain, DynamoDB data source, resolvers, related IAM
├── audio_delivery.tf  # CloudFront for audio/ in the data bucket
├── auth.tf            # Cognito User Pool and CMS app client
├── cms_hosting.tf     # S3 + CloudFront for the CMS
├── domain.tf          # Custom domain names and their ACM wildcard certificate (us-east-1)
├── outputs.tf         # Values consumed by backend/CMS deployments
└── graphql/
    ├── schema.graphql # CMS-facing GraphQL schema
    ├── resolvers/     # APPSYNC_JS resolvers, one file per field
    └── tests/         # Resolver test cases, one file per resolver
```

There is a single root module and a single environment. Files are split by component instead of Terraform modules, and IAM is defined next to the resource that uses it.

## Boundaries

### Backend (`vibratio-backend`)

The backend repository owns the code of the batch Lambda function. It uses the `provided.al2023` runtime on `arm64` and expects a Go binary named `bootstrap`.

| Function | Trigger | Environment variables |
| --- | --- | --- |
| `vibratio-batch` | EventBridge Scheduler, once a day | `AUDIO_BASE_URL`, `CONFIG_TABLE_NAME`, `DATA_BUCKET_NAME`, `SECRETS_PARAMETER_PATH` |

Terraform creates the function with a placeholder package and ignores later code changes, so function code is deployed independently:

```sh
aws lambda update-function-code --function-name vibratio-batch --zip-file fileb://batch.zip
```

The URL posted to Discord for an audio object `audio/<key>` is `${AUDIO_BASE_URL}/audio/<key>`. Anyone with the URL can download the file, so `<key>` must contain an unguessable part such as a UUID. Set `Content-Type` (e.g. `audio/mpeg`) on upload so that the file plays in the browser.

Runtime settings (memory, timeout, environment variables, IAM) stay in Terraform.

### CMS (`vibratio-cms`)

The CMS is a static SPA. It signs in with Cognito (SRP, no hosted UI) and calls AppSync with the Cognito ID token. Build-time settings come from Terraform outputs:

| Output | Usage |
| --- | --- |
| `graphql_api_url` | AppSync endpoint on the custom domain |
| `cognito_user_pool_id` | Cognito user pool |
| `cognito_user_pool_client_id` | Cognito app client |

All resources are in `ap-northeast-1`.

Deploy the build output and invalidate the cache:

```sh
aws s3 sync dist "s3://$(terraform -chdir=terraform output -raw cms_bucket_name)" --delete
aws cloudfront create-invalidation --distribution-id "$(terraform -chdir=terraform output -raw cms_distribution_id)" --paths "/*"
```

### GraphQL API

`terraform/graphql/schema.graphql` is the CMS-facing schema, and `terraform/graphql/resolvers/<Type>.<field>.js` resolves each `Query` and `Mutation` field against the config table. Terraform registers every file in `resolvers/` as a resolver, so adding a field means adding it to the schema and adding its resolver file.

Resolvers are plain JavaScript files deployed as they are, with no build step. They run on the APPSYNC_JS runtime, which supports only a subset of JavaScript (no `try`/`catch`, classes, `while` loops, ...).

#### Resolver Tests

`scripts/test-resolvers.sh` runs each resolver on the APPSYNC_JS runtime with `aws appsync evaluate-code`, so the tests catch unsupported JavaScript as well as wrong DynamoDB requests. Nothing is deployed or written. Every resolver must have a test file `terraform/graphql/tests/<Type>.<field>.json` with an array of cases:

| Key | Description |
| --- | --- |
| `name` | Description of the case |
| `function` | `request` or `response` |
| `context` | AppSync context passed to the function (`arguments`, `result`, `error`, ...) |
| `expected` | Expected return value |
| `ignore` | Optional paths removed from the return value before comparing, for generated IDs and timestamps (e.g. `[["key", "sk"]]`) |
| `expectedError` | Expected error message, instead of `expected` |

```sh
./scripts/test-resolvers.sh   # requires AWS credentials with appsync:EvaluateCode
```

## Data Model

### DynamoDB Config Table

`vibratio-config` stores the settings edited from the CMS. AppSync reads and writes it; the batch only reads it.

| `pk` | `sk` | Attributes |
| --- | --- | --- |
| `SOURCE` | Source ID (UUID) | `name`, `type`, `endpoint`, `createdAt`, `updatedAt` |

Each kind of setting gets its own partition key, so the batch and the CMS read all items of a kind with one `Query`. Single-item settings can use a fixed sort key such as `pk = SETTINGS`, `sk = default`.

### S3 Data Bucket

Data generated by the batch lives in `vibratio-data-<account-id>`.

| Prefix | Content | Batch |
| --- | --- | --- |
| `articles/` | `Article` collected from sources | read / write |
| `episodes/` | `Episode` including its `Script` | read / write |
| `audio/` | `Audio` generated by TTS | write |

`audio/` is also readable through the audio CloudFront distribution (bucket policy restricted to that distribution); the other prefixes are not.

The prefixes map one-to-one to the backend domain model, and IAM policies are scoped by them. Object keys below each prefix and their formats are defined by the backend domain design. For example, sortable Episode IDs such as dates make `ListObjectsV2` on `episodes/` return episodes in order.

## Design Decisions

- **Settings in DynamoDB, generated data in S3.** Settings are small records edited one at a time, which fits DynamoDB (conditional writes, `Query` instead of list-then-get). Articles, episodes and audio are written once a day and audio is large, which fits S3. The config table has point-in-time recovery and deletion protection because it is the only copy of the settings. The data bucket is versioned because regenerating episodes calls paid APIs again; noncurrent versions expire after 30 days.
- **Lambda code is deployed outside Terraform.** Terraform owns the function configuration, the backend CI owns the code. This keeps application releases independent from infrastructure changes.
- **No automatic retry of the batch.** Retries would call the paid LLM and TTS APIs again, so a failed run is re-executed manually (see Operations).
- **SSM Parameter Store instead of Secrets Manager.** Standard SecureString parameters are free and rotation is not needed. Terraform creates the parameters with a write-only placeholder value (`value_wo`) and never reads the value back, so real credentials never enter the Terraform state.
- **AppSync JS resolvers instead of a BFF Lambda.** The CMS only performs CRUD on settings, so resolvers map GraphQL fields to DynamoDB operations directly. Type and URL checks come from the schema (`AWSURL`, enums). If validation grows beyond what a resolver should do, a Lambda data source can be added for those fields.
- **Cognito without self sign-up.** The CMS is for personal use; users are created by an administrator. TOTP MFA is available as an option.
- **Audio is delivered as a public CloudFront URL.** The batch posts the URL to Discord, and Discord messages remain, so the URL must not expire; presigned URLs expire within hours when signed with Lambda role credentials. CloudFront reads only `audio/` through origin access control, and unguessable object keys keep the files from being enumerated. If the files must be restricted, CloudFront signed URLs with a long expiry can be added later. The CMS and the API have no access to the data bucket.
- **Custom domains under `vibratio.cl17.dev` with DNS on Cloudflare.** One wildcard ACM certificate (`*.vibratio.cl17.dev`) in `us-east-1`, as CloudFront and AppSync require, covers `cms`, `audio` and `api`. DNS is not moved to Route 53, so the validation and service records are added to Cloudflare by hand. The custom domains reference the certificate through `aws_acm_certificate_validation`, so they are configured only after the certificate is issued. The records are DNS only: proxying through Cloudflare would put a second CDN in front of CloudFront, doubling cache and TLS handling, and Cloudflare's Flexible SSL mode would cause a redirect loop.

## Deployment

`terraform plan` and `terraform apply` are run by GitHub Actions. The state bucket and the GitHub Actions roles are set up once by hand.

### Prerequisites

- Terraform `>= 1.11`
- An S3 bucket for the Terraform state in `ap-northeast-1`. Locking uses an S3 lock file in the same bucket, so no DynamoDB table is required.

The state bucket is created once by hand because Terraform cannot store its own state in a bucket it manages:

```sh
BUCKET="vibratio-tfstate-$(aws sts get-caller-identity --query Account --output text)"
aws s3api create-bucket --bucket "$BUCKET" --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
```

The GitHub Actions roles are also created by hand, using the existing `token.actions.githubusercontent.com` OIDC provider. Plan and apply use separate roles so that pull requests never get write access to AWS:

| Role | Trust condition (`token.actions.githubusercontent.com:sub`, `StringLike`) | Permissions |
| --- | --- | --- |
| `vibratio-github-actions-plan` | `repo:Eagle-Konbu@13817030/vibratio-infra@1401080650:pull_request` | `ReadOnlyAccess`, plus `s3:PutObject` / `s3:DeleteObject` on `vibratio/terraform.tfstate.tflock` in the state bucket, and `appsync:EvaluateCode` for the resolver tests |
| `vibratio-github-actions-apply` | `repo:Eagle-Konbu@13817030/vibratio-infra@1401080650:ref:refs/tags/v*` | `AdministratorAccess` |

Both trust policies also require `token.actions.githubusercontent.com:aud` to be `sts.amazonaws.com` (`StringEquals`).

The repository uses GitHub's immutable OIDC subject, which includes the owner and repository IDs (`<owner>@<owner-id>/<repo>@<repo-id>`). A renamed or re-created repository therefore cannot assume these roles. Check the current prefix with `gh api repos/Eagle-Konbu/vibratio-infra/actions/oidc/customization/sub`.

### CI/CD

| Workflow | Trigger | Steps |
| --- | --- | --- |
| `ci.yml` | Pull request that changes `terraform/` | TFLint, resolver tests, and fmt check, validate, plan with a plan comment on the pull request (jobs run in parallel) |
| `deploy.yml` | Push of a `v*.*.*` tag | plan and apply |

Release by tagging the merged commit on `main`:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Repository secrets:

| Secret | Value |
| --- | --- |
| `AWS_PLAN_ROLE_ARN` | ARN of the plan role |
| `AWS_APPLY_ROLE_ARN` | ARN of the apply role |
| `TF_STATE_BUCKET` | Name of the state bucket |

This repository is public, so workflow logs and plan comments are public too. They contain resource ARNs, including the AWS account ID, but no credentials. Pull requests from forks receive neither secrets nor OIDC tokens, so their plan job fails without touching AWS.

### Local Validation

`terraform plan` and `terraform apply` are not run locally. To validate without access to the state, run in `terraform/`:

```sh
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
tflint --init
tflint
../scripts/test-resolvers.sh
```

`.terraform.lock.hcl` contains provider hashes for `linux_amd64` and `darwin_arm64`. After upgrading providers, refresh it with:

```sh
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

### First Apply

The custom domains wait for the ACM certificate to be issued, which in turn needs the validation records in Cloudflare (see step 3 below). On a fresh setup, the apply job therefore blocks on `aws_acm_certificate_validation` until the records exist. Add them while it waits, reading them from ACM because the Terraform outputs are not written yet:

```sh
aws acm describe-certificate --region us-east-1 \
  --certificate-arn "$(aws acm list-certificates --region us-east-1 --query "CertificateSummaryList[?DomainName=='*.vibratio.cl17.dev'].CertificateArn" --output text)" \
  --query "Certificate.DomainValidationOptions[].ResourceRecord"
```

### After the First Apply

1. Set the external API credentials and the Discord webhook URL (`batch_secret_parameter_names` output):

   ```sh
   aws ssm put-parameter --name /vibratio/batch/llm-api-key --type SecureString --overwrite --value '<value>'
   aws ssm put-parameter --name /vibratio/batch/tts-api-key --type SecureString --overwrite --value '<value>'
   aws ssm put-parameter --name /vibratio/batch/discord-webhook-url --type SecureString --overwrite --value '<value>'
   ```

2. Create the CMS user:

   ```sh
   aws cognito-idp admin-create-user \
     --user-pool-id "$(terraform -chdir=terraform output -raw cognito_user_pool_id)" \
     --username <email> \
     --user-attributes Name=email,Value=<email> Name=email_verified,Value=true
   ```

3. Validate the ACM certificate by adding its DNS records to Cloudflare (`cl17.dev` → DNS → Records):

   ```sh
   terraform -chdir=terraform output acm_validation_records
   ```

   - Add each record as a CNAME with Proxy status **DNS only** (grey cloud); ACM cannot validate proxied records.
   - Cloudflare strips the trailing `.cl17.dev` from the name, so check the displayed name after saving.
   - If `cl17.dev` has CAA records, add `0 issue "amazon.com"` and `0 issuewild "amazon.com"`.
   - Keep the records; ACM uses them to renew the certificate.

   Confirm that the certificate is `ISSUED`:

   ```sh
   AWS_REGION=us-east-1 aws acm list-certificates --query "CertificateSummaryList[?DomainName=='*.vibratio.cl17.dev']"
   ```

4. Point the custom domains to AWS by adding the records from `custom_domain_dns_records` to Cloudflare, also as **DNS only** CNAMEs:

   ```sh
   terraform -chdir=terraform output custom_domain_dns_records
   ```

   | Name | Target |
   | --- | --- |
   | `cms.vibratio` | CMS distribution (`<id>.cloudfront.net`) |
   | `audio.vibratio` | Audio distribution (`<id>.cloudfront.net`) |
   | `api.vibratio` | AppSync custom domain (`<id>.cloudfront.net`) |

5. Deploy the backend Lambda code and the CMS as described in [Boundaries](#boundaries).

## Operations

Run the batch manually, for example after a failure:

```sh
aws lambda invoke --function-name vibratio-batch --invocation-type Event /dev/null
```

Logs:

| Component | Log group |
| --- | --- |
| Batch | `/aws/lambda/vibratio-batch` |
| AppSync (errors only) | `/aws/appsync/apis/<api-id>` |

## Estimated Cost

Rough monthly estimate in `ap-northeast-1` for one batch per day and a single CMS user. External LLM and TTS APIs are not included.

| Service | Assumption | Monthly |
| --- | --- | --- |
| Lambda | 30 runs × up to 15 min × 512 MB ≈ 13,500 GB-s | $0 (within the always-free 400,000 GB-s) |
| EventBridge Scheduler | 30 invocations | $0 (within the 14M free invocations) |
| S3 | ~10 MB of audio per episode, growing ~0.3 GB per month | < $0.10 |
| AppSync | A few thousand requests | < $0.05 |
| DynamoDB | On-demand, a few thousand requests, < 1 MB stored, point-in-time recovery | < $0.01 |
| CloudFront | CMS assets and ~0.3 GB of audio downloads | $0 (within the always-free 1 TB) |
| Cognito | 1 MAU | $0 (within the free MAU) |
| CloudWatch Logs | < 1 GB ingestion | $0 (within the 5 GB free tier) |
| SSM Parameter Store | Standard parameters | $0 |
| ACM | Public certificate | $0 |
| Terraform state bucket | A few KB | < $0.01 |
| **Total** | | **< $1** |

Storage is the only cost that grows over time. If it becomes significant, add a lifecycle rule for `audio/`.
