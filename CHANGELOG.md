# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2025-03-18

- Added `-SkipWorkspace` to support Terraform Cloud where custom workspace flow is not valid. Thanks @richclement

## [2.0.4] - 2025-03-04

- Fixed issue with latest version endpoint started including prefixed `v`, e.g. `v1.11.0` which is not in the download URI

## [2.0.3] - 2024-09-29

- Updated Terraform Workspaces to only include letters, numbers, hyphens, underscores

## [2.0.2] - 2023-11-09

- Fixed param type

## [2.0.1] - 2023-11-06

- Fixed invocations missing new splat
- Fixed issue if `CreateHardLink` fails due to `terraform` binary in use

## [2.0.0] - 2023-11-05

- Update config search behavior

## [1.1.0] - 2023-11-04

- Added automatic version install
- Updated config to support specifying version
- Added support for hard link
- Update config to support creating hard link

## [1.0.2] - 2020-11-01

- Removed `init` on default workspace for workspace delete

## [1.0.1] - 2020-11-01

- Fixed issue with `Clear-TerraformEnvironment` unnecessarily running every time, causing workspace change every time
- Fixed issue with `Set-TerraformWorkspace` not running `terraform init` after a workspace change
- Fixed issue with `Set-TerraformWorkspace` using `-cmatch` vs `-ccontains` causing issues when workspaces were a substring of another workspace

## [1.0.0] - 2020-02-29

- Initial release
