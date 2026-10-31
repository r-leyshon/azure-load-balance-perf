# OIDC Setup for GitHub Actions → Azure

The scheduled destroy workflow uses OpenID Connect federated credentials — no long-lived secrets
stored in GitHub. Follow these steps once before the workflow can run.

## 1. Create an Entra app registration

```bash
az ad app create --display-name "gh-apim-foundry-perf"
```

Note the `appId` output — this is your `AZURE_CLIENT_ID`.

## 2. Create a service principal for the app

```bash
az ad sp create --id <appId>
```

## 3. Add a federated credential

In the Azure portal: **Entra ID → App registrations → gh-apim-foundry-perf → Certificates & secrets → Federated credentials → Add**.

| Field | Value |
|---|---|
| Scenario | GitHub Actions deploying Azure resources |
| Organisation | your GitHub org or username |
| Repository | azure-load-balance-perf |
| Entity type | Branch |
| Branch | main |

Or via CLI:

```bash
az ad app federated-credential create \
  --id <appId> \
  --parameters '{
    "name": "gh-main-branch",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:<org>/azure-load-balance-perf:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

## 4. Assign permissions on the sandbox subscription

```bash
SUBSCRIPTION_ID="<your-sandbox-subscription-id>"
SP_OBJECT_ID=$(az ad sp show --id <appId> --query id -o tsv)

# Contributor to create/destroy all resources
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role Contributor \
  --scope "/subscriptions/$SUBSCRIPTION_ID"

# User Access Administrator to create role assignments (managed identity RBAC)
az role assignment create \
  --assignee-object-id "$SP_OBJECT_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "User Access Administrator" \
  --scope "/subscriptions/$SUBSCRIPTION_ID"
```

## 5. Add GitHub Actions secrets and variables

In your repository: **Settings → Secrets and variables → Actions**.

| Secret name | Value |
|---|---|
| `AZURE_CLIENT_ID` | App registration `appId` |
| `AZURE_TENANT_ID` | Your Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Sandbox subscription ID |
| `TF_PUBLISHER_NAME` | APIM publisher name |
| `TF_PUBLISHER_EMAIL` | APIM publisher email |

Optionally set `RESOURCE_GROUP_NAME` as a **variable** (not secret) if you changed the default.

## 6. Configure Terraform remote state

The destroy workflow needs access to the same Terraform state used during `terraform apply`.
Create a storage account **outside** the perf resource group so state survives the destroy:

```bash
az group create -n rg-tfstate -l uksouth
az storage account create -n <unique-name> -g rg-tfstate --sku Standard_LRS
az storage container create -n tfstate --account-name <unique-name>
```

Uncomment and fill in the `backend "azurerm"` block in `infra/main.tf`, then run:

```bash
terraform init -migrate-state
```
