#!/usr/bin/env bash

set -euo pipefail

required_files=(
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/workflows/build.yml"
  "AGENTS.md"
  "LICENSE"
  "README.md"
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

failed=0

while IFS= read -r proposal_directory; do
  proposal_name="${proposal_directory#proposals/}"

  if [[ ! "${proposal_name}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Invalid proposal directory name: ${proposal_directory}" >&2
    echo "Expected proposals/YYYY-MM-DD-kebab-case-name" >&2
    failed=1
    continue
  fi

  proposal_date="${proposal_name:0:10}"
  if validated_date="$(date -d "${proposal_date}" +%F 2>/dev/null)"; then
    :
  elif validated_date="$(date -j -f "%Y-%m-%d" "${proposal_date}" +%F 2>/dev/null)"; then
    :
  else
    echo "Unparseable proposal date: ${proposal_date}" >&2
    echo "Expected a real calendar date in YYYY-MM-DD format" >&2
    failed=1
    continue
  fi

  if [[ "${validated_date}" != "${proposal_date}" ]]; then
    echo "Non-canonical proposal date: ${proposal_date}" >&2
    echo "Date command normalized it to: ${validated_date}" >&2
    failed=1
    continue
  fi

  if [[ ! -f "${proposal_directory}/README.md" ]]; then
    echo "Proposal is missing README.md: ${proposal_directory}" >&2
    failed=1
  fi
done < <(find proposals -mindepth 1 -maxdepth 1 -type d -print | sort)

if (( failed )); then
  exit 1
fi

echo "Repository structure is valid."
