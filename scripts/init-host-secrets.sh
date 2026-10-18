#!/usr/bin/env bash
# 미니 PC용 호스트 시크릿 파일을 처음 만든다 (관리 PC WSL에서, repo 루트에서 실행).
# 평문을 디스크에 쓰지 않고 바로 SOPS로 암호화한다. 이미 파일이 있으면 아무것도 하지 않는다.
# 값을 바꿀 때는: sops ansible/inventory/host_vars/homelab/secrets.sops.yaml
set -euo pipefail

out="ansible/inventory/host_vars/homelab/secrets.sops.yaml"

if [[ -e "${out}" ]]; then
  echo "이미 있음: ${out} (수정은 sops로)"
  exit 0
fi
if [[ ! -f "${HOME}/.config/sops/age/keys.txt" ]]; then
  echo "age 키가 없습니다: ~/.config/sops/age/keys.txt" >&2
  exit 1
fi

echo "Bitwarden의 homelab-k3s-backup 항목에서 복사해 붙여넣으세요 (입력 내용은 화면에 보이지 않음)"
read -rsp "액세스 키 ID (AKIA로 시작, 20자): " access_key; echo
read -rsp "비밀 액세스 키 (40자): " secret_key; echo

if [[ ! "${access_key}" =~ ^AKIA[A-Z0-9]{16}$ ]]; then
  echo "액세스 키 ID 형식이 아닙니다 (AKIA + 대문자·숫자 16자)" >&2
  exit 1
fi
if [[ ${#secret_key} -ne 40 ]]; then
  echo "비밀 액세스 키 길이가 40자가 아닙니다 (${#secret_key}자)" >&2
  exit 1
fi

# k3s 토큰: 새 호스트에서 스냅샷을 복원할 때도 같은 값이 필요하므로 여기서 한 번 만들어 고정한다
token="$(openssl rand -hex 32)"

trap 'rm -f "${out}.tmp"' EXIT
printf 'k3s_token: "%s"\nk3s_etcd_s3_access_key: "%s"\nk3s_etcd_s3_secret_key: "%s"\n' \
  "${token}" "${access_key}" "${secret_key}" \
  | sops --encrypt --filename-override "${out}" --input-type yaml --output-type yaml /dev/stdin > "${out}.tmp"
mv "${out}.tmp" "${out}"
echo "만듦: ${out} (암호화됨)"
