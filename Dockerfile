ARG TERRAFORM_VERSION=latest
ARG POWERSHELL_VERSION=latest
FROM hashicorp/terraform:${TERRAFORM_VERSION} as terraform
FROM mcr.microsoft.com/powershell:${POWERSHELL_VERSION}

# Copy over Terraform binary
COPY --from=terraform /bin/terraform /bin/terraform

# Setup terraposh module
COPY terraposh.ps* /usr/local/share/powershell/Modules/terraposh/
