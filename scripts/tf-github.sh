#!/usr/bin/env bash
# terraform/github 실행 (관리 PC). 사용: tf-github.sh plan|apply
# GitHub 토큰은 화면에 보이지 않게 입력받아 이 프로세스의 환경 변수로만 쓴다 (셸 기록·파일에 남지 않음)
set -euo pipefail

cmd="${1:-}"
[[ "${cmd}" == "plan" || "${cmd}" == "apply" ]] || {
  echo "사용: tf-github.sh plan|apply" >&2
  exit 2
}

cd "$(dirname "$0")/../terraform/github"
profile=homelab-tfstate

# state는 S3에 있다. WSL은 브라우저를 직접 못 열어서 코드 입력 방식으로 로그인한다
aws sts get-caller-identity --profile "${profile}" >/dev/null 2>&1 ||
  aws sso login --profile "${profile}" --use-device-code

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  read -rsp "GitHub 토큰 (입력이 보이지 않음): " GITHUB_TOKEN
  echo
fi
export GITHUB_TOKEN

terraform init -input=false >/dev/null
terraform "${cmd}"
