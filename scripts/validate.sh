#!/usr/bin/env bash

set -euo pipefail

required_files=(
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/workflows/build.yml"
  "AGENTS.md"
  "LICENSE"
  "README.md"
  "proposals/README.md"
  "scripts/validate.sh"
  "templates/design-proposal.md"
)

required_directories=(
  ".github/workflows"
  "proposals"
  "scripts"
  "templates"
)

for path in "${required_files[@]}"; do
  if [[ ! -f "${path}" ]]; then
    echo "Required file is missing: ${path}" >&2
    exit 1
  fi
done

for path in "${required_directories[@]}"; do
  if [[ ! -d "${path}" ]]; then
    echo "Required directory is missing: ${path}" >&2
    exit 1
  fi
done

while IFS= read -r proposal_directory; do
  proposal_name="${proposal_directory#proposals/}"

  if [[ ! "${proposal_name}" =~ ^[0-9]{4}-[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Invalid proposal directory name: ${proposal_directory}" >&2
    echo "Expected proposals/NNNN-kebab-case-name" >&2
    exit 1
  fi

  if [[ ! -f "${proposal_directory}/README.md" ]]; then
    echo "Proposal is missing README.md: ${proposal_directory}" >&2
    exit 1
  fi
done < <(find proposals -mindepth 1 -maxdepth 1 -type d -print | sort)

echo "Repository structure is valid."
