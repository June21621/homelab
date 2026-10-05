#!/usr/bin/env bash
# 관리 PC(WSL2 Ubuntu 24.04)에 홈랩 운영 도구를 설치한다.
# 멱등: 이미 같은 버전이 있으면 건너뛴다. 일반 사용자로 실행 (apt 단계만 sudo).
set -euo pipefail

TERRAFORM_VERSION="1.16.5"
SOPS_VERSION="3.13.3"
UV_VERSION="0.12.23"
ANSIBLE_CORE_VERSION="2.21.4"
ANSIBLE_LINT_VERSION="26.9.0"
PRE_COMMIT_VERSION="4.6.2"

if [[ "${EUID}" -eq 0 ]]; then
  echo "root가 아닌 일반 사용자로 실행하세요 (필요한 단계만 sudo 사용)" >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }

# --- apt 패키지 -------------------------------------------------------------
log "apt 기본 패키지"
sudo apt-get update -qq
sudo apt-get install -y -qq age shellcheck curl gnupg unzip ca-certificates make

# --- WSL: Windows 드라이브(/mnt/c) 권한 --------------------------------------
# 기본값은 파일 소유자가 root(uid=0)라 git이 chmod를 못 하고 Ansible이 ansible.cfg를 무시한다.
# metadata로 리눅스 권한을 저장하고 소유자를 현재 사용자로 맞춘다. 적용엔 `wsl --shutdown` 필요.
log "WSL automount 옵션"
if ! grep -q '^\[automount\]' /etc/wsl.conf 2>/dev/null; then
  printf '\n[automount]\noptions = "metadata,uid=%s,gid=%s,umask=22,fmask=11"\n' "$(id -u)" "$(id -g)" \
    | sudo tee -a /etc/wsl.conf >/dev/null
  echo "!! /etc/wsl.conf 변경됨 → PowerShell에서 'wsl --shutdown' 후 Ubuntu를 다시 여세요"
fi

# --- Terraform (HashiCorp apt 저장소, 서명 검증) ----------------------------
log "Terraform ${TERRAFORM_VERSION}"
keyring=/usr/share/keyrings/hashicorp-archive-keyring.gpg
if [[ ! -f "${keyring}" ]]; then
  curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o "${keyring}"
fi
codename="$(lsb_release -cs)"
echo "deb [arch=amd64 signed-by=${keyring}] https://apt.releases.hashicorp.com ${codename} main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
if [[ "$(terraform version -json 2>/dev/null | grep -o '"terraform_version": *"[^"]*"' | grep -o '[0-9][0-9.]*')" != "${TERRAFORM_VERSION}" ]]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq --allow-downgrades "terraform=${TERRAFORM_VERSION}-*"
fi
sudo apt-mark hold terraform >/dev/null

# --- SOPS (GitHub 릴리스 바이너리, 체크섬 검증) ------------------------------
# .deb는 체크섬 파일에 없어서 체크섬이 있는 단일 바이너리를 쓴다
log "SOPS ${SOPS_VERSION}"
if [[ "$(sops --version 2>/dev/null | grep -o '[0-9][0-9.]*' | head -1)" != "${SOPS_VERSION}" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  base="https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}"
  bin="sops-v${SOPS_VERSION}.linux.amd64"
  curl -fsSL -o "${tmp}/${bin}" "${base}/${bin}"
  curl -fsSL -o "${tmp}/checksums.txt" "${base}/sops-v${SOPS_VERSION}.checksums.txt"
  (cd "${tmp}" && grep " ${bin}\$" checksums.txt | sha256sum -c -)
  sudo install -m 0755 "${tmp}/${bin}" /usr/local/bin/sops
fi

# --- uv (Python 도구 관리) --------------------------------------------------
log "uv ${UV_VERSION}"
export PATH="${HOME}/.local/bin:${PATH}"
if [[ "$(uv --version 2>/dev/null | awk '{print $2}')" != "${UV_VERSION}" ]]; then
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh
fi

# --- Python 도구 (uv tool로 버전 고정, 각자 격리된 venv) ---------------------
log "ansible-core ${ANSIBLE_CORE_VERSION}, ansible-lint ${ANSIBLE_LINT_VERSION}, pre-commit ${PRE_COMMIT_VERSION}"
uv tool install --quiet "ansible-core==${ANSIBLE_CORE_VERSION}"
uv tool install --quiet "ansible-lint==${ANSIBLE_LINT_VERSION}"
uv tool install --quiet "pre-commit==${PRE_COMMIT_VERSION}"

# --- 결과 -------------------------------------------------------------------
log "설치 결과"
terraform version | head -1
sops --version | head -1
age --version
shellcheck --version | sed -n 2p
uv --version
ansible --version | head -1
ansible-lint --version | head -1
pre-commit --version

if ! grep -q '.local/bin' "${HOME}/.bashrc" 2>/dev/null && [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  echo
  echo "새 터미널에서 ~/.local/bin 이 PATH에 없으면: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
fi
