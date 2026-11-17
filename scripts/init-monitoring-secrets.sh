#!/usr/bin/env bash
# monitoring 앱의 비밀값 파일을 처음 만든다 (관리 PC WSL에서, repo 루트에서 실행).
# 평문을 디스크에 쓰지 않고 바로 SOPS로 암호화한다. 이미 파일이 있으면 아무것도 하지 않는다.
# 값을 바꿀 때는: sops gitops/platform/monitoring/secrets.sops.yaml
#
# 만드는 Secret (namespace monitoring, 6단계 설계 §3.3):
#   alertmanager-receivers: discord-webhook-url, healthchecks-ping-url  → Alertmanager가 파일로 읽음
#   grafana-admin: admin-user, admin-password                            → Grafana 관리자 계정
set -euo pipefail

out="gitops/platform/monitoring/secrets.sops.yaml"

if [[ -e "${out}" ]]; then
  echo "이미 있음: ${out} (수정은 sops로)"
  exit 0
fi
if [[ ! -f "${HOME}/.config/sops/age/keys.txt" ]]; then
  echo "age 키가 없습니다: ~/.config/sops/age/keys.txt" >&2
  exit 1
fi

echo "붙여넣으세요 (입력 내용은 화면에 보이지 않음)"
read -rsp "Discord 웹훅 URL (https://discord.com/api/webhooks/...): " discord; echo
read -rsp "healthchecks.io Ping URL (https://hc-ping.com/...): " healthchecks; echo

if [[ ! "${discord}" =~ ^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]]; then
  echo "Discord 웹훅 URL 형식이 아닙니다 (https://discord.com/api/webhooks/<숫자>/<토큰>)" >&2
  exit 1
fi
if [[ ! "${healthchecks}" =~ ^https://hc-ping\.com/[A-Za-z0-9/_-]+$ ]]; then
  echo "healthchecks.io Ping URL 형식이 아닙니다 (https://hc-ping.com/...)" >&2
  exit 1
fi

# Grafana 관리자 비밀번호는 여기서 만든다. 화면에 띄우지 않고 Windows 클립보드로만 넘긴다
grafana_password="$(openssl rand -base64 24)"

trap 'rm -f "${out}.tmp"' EXIT
cat <<EOF | sops --encrypt --filename-override "${out}" --input-type yaml --output-type yaml /dev/stdin >"${out}.tmp"
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-receivers
  namespace: monitoring
type: Opaque
stringData:
  discord-webhook-url: "${discord}"
  healthchecks-ping-url: "${healthchecks}"
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: monitoring
type: Opaque
stringData:
  admin-user: admin
  admin-password: "${grafana_password}"
EOF
mv "${out}.tmp" "${out}"
echo "만듦: ${out} (암호화됨)"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "${grafana_password}" | clip.exe
  echo "Grafana 관리자 비밀번호(사용자 admin)를 클립보드에 복사했습니다. Bitwarden \"homelab-grafana-admin\"에 붙여넣어 저장하세요."
else
  echo "clip.exe가 없어 비밀번호를 복사하지 못했습니다. 저장은: sops -d ${out} 로 확인 후 Bitwarden에" >&2
fi
