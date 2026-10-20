#!/usr/bin/env bash
# pre-commit 훅: secrets/ 아래·*.sops.yaml 파일이 SOPS로 암호화돼 있는지 확인한다.
# 인자로 받은 파일 중 하나라도 평문이면 non-zero로 종료한다.
set -euo pipefail

status=0
for f in "$@"; do
  if ! grep -q '^sops:' "${f}" || ! grep -q 'ENC\[' "${f}"; then
    echo "평문 시크릿 의심: ${f} (sops --encrypt 후 커밋하세요)" >&2
    status=1
  fi
done
exit "${status}"
