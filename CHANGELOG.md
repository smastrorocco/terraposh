# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2020-11-01

- Fixed issue with `Clear-TerraformEnvironment` unnecessarily running every time, causing workspace change every time
- Fixed issue with `Set-TerraformWorkspace` not running `terraform init` after a workspace change
- Fixed issue with `Set-TerraformWorkspace` using `-cmatch` vs `-ccontains` causing issues when workspaces were a substring of another workspace

## [1.0.0] - 2020-02-29

- Initial release
