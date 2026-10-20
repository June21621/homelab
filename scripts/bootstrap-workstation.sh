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
AWSCLI_VERSION="2.37.13"
# 2026-10-14 AWS CLI 팀 PGP 서명(FB5DB77FD5C118B80511ADA8A6310ACC4672475C) 확인 후 고정
AWSCLI_SHA256="c92fde59827622889d3d38a44e2089a137894ce151a2c658a3988ecde4860caa"
# k3s(v1.36.5+k3s1)와 같은 마이너. dl.k8s.io의 .sha256 값(2026-10-18 확인)을 고정
KUBECTL_VERSION="1.36.5"
KUBECTL_SHA256="33bc88a24c3b09cf55bfd59e6ca977881b61fc3f25ab65bc80c65b430248648e"

if [[ "${EUID}" -eq 0 ]]; then
  echo "root가 아닌 일반 사용자로 실행하세요 (필요한 단계만 sudo 사용)" >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }

# --- apt 패키지 -------------------------------------------------------------
log "apt 기본 패키지"
sudo apt-get update -qq
sudo apt-get install -y -qq age shellcheck curl gnupg unzip ca-certificates make

# --- ssh-agent ---------------------------------------------------------------
# Ansible은 SSH 키 passphrase를 물을 수 없어 agent가 필요하다.
# eval 없이 고정 소켓 경로를 쓰고, 키는 agent에 1시간만 올려 둔다(make host가 필요할 때 ssh-add -t 1h).
log "ssh-agent 고정 소켓을 ~/.bashrc에 등록"
marker='# >>> homelab ssh-agent >>>'
if ! grep -qxF "${marker}" "${HOME}/.bashrc"; then
  cat >> "${HOME}/.bashrc" <<'BASHRC'

# >>> homelab ssh-agent >>>
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-$HOME/.ssh}/ssh-agent.socket"
ssh-add -l >/dev/null 2>&1
if [ $? -eq 2 ]; then  # 2 = agent 없음 (0 = 키 있음, 1 = 키 없음)
  rm -f "$SSH_AUTH_SOCK"
  ssh-agent -a "$SSH_AUTH_SOCK" >/dev/null
fi
# <<< homelab ssh-agent <<<
BASHRC
fi

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

# --- kubectl (dl.k8s.io 바이너리, 체크섬 고정) -------------------------------
log "kubectl ${KUBECTL_VERSION}"
if [[ "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"v[^"]*"' | grep -o '[0-9][0-9.]*')" != "${KUBECTL_VERSION}" ]]; then
  kubetmp="$(mktemp -d)"
  curl -fsSL -o "${kubetmp}/kubectl" "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  echo "${KUBECTL_SHA256}  ${kubetmp}/kubectl" | sha256sum -c -
  sudo install -m 0755 "${kubetmp}/kubectl" /usr/local/bin/kubectl
  rm -rf "${kubetmp}"
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

# --- AWS CLI v2 (aws sso login용, 사용자 영역 설치라 sudo 불필요) -------------
log "AWS CLI ${AWSCLI_VERSION}"
if [[ "$(aws --version 2>/dev/null | sed -E 's#^aws-cli/([0-9.]+).*#\1#')" != "${AWSCLI_VERSION}" ]]; then
  awstmp="$(mktemp -d)"
  curl -fsSL -o "${awstmp}/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip"
  echo "${AWSCLI_SHA256}  ${awstmp}/awscli.zip" | sha256sum -c -
  unzip -q "${awstmp}/awscli.zip" -d "${awstmp}"
  "${awstmp}/aws/install" -i "${HOME}/.local/aws-cli" -b "${HOME}/.local/bin" --update
  rm -rf "${awstmp}"
fi

# --- 결과 -------------------------------------------------------------------
log "설치 결과"
# head -1은 첫 줄만 읽고 먼저 끝나 앞 명령이 SIGPIPE(141)로 죽을 수 있다(pipefail이면 스크립트 실패).
# sed -n 1p는 입력을 끝까지 읽으므로 안전하다
terraform version | sed -n 1p
sops --version | sed -n 1p
kubectl version --client | sed -n 1p
age --version
shellcheck --version | sed -n 2p
uv --version
ansible --version | sed -n 1p
ansible-lint --version | sed -n 1p
pre-commit --version
aws --version

if ! grep -q '.local/bin' "${HOME}/.bashrc" 2>/dev/null && [[ ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  echo
  echo "새 터미널에서 ~/.local/bin 이 PATH에 없으면: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
fi
