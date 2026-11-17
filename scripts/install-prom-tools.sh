#!/usr/bin/env bash
# promtool(규칙 검사·테스트)과 amtool(Alertmanager 설정 검사)을 버전·체크섬 고정으로 설치한다.
# 관리 PC(scripts/bootstrap-workstation.sh)와 CI(static-checks)가 같이 쓴다. 버전은 이 파일 한 곳.
#   사용: install-prom-tools.sh [설치 폴더, 기본 /usr/local/bin]
# 버전은 kube-prometheus-stack 92.17.0에 든 Prometheus·Alertmanager와 같은 것 (6단계 설계 §3.1)
set -euo pipefail

PROMETHEUS_VERSION="3.15.1"
ALERTMANAGER_VERSION="0.34.2"
BIN_DIR="${1:-/usr/local/bin}"

SUDO=""
if [[ ! -w "${BIN_DIR}" ]]; then
  SUDO="sudo"
fi

# install_tool <도구> <프로젝트> <버전>
install_tool() {
  local tool="$1" project="$2" version="$3"
  # sed -n 1p: head -1과 달리 끝까지 읽어 앞 명령이 SIGPIPE로 죽지 않는다(bootstrap-workstation.sh와 같은 이유)
  if [[ "$("${BIN_DIR}/${tool}" --version 2>&1 | sed -n 1p)" == *"version ${version} "* ]]; then
    echo "${tool} ${version} 이미 설치됨"
    return
  fi
  local tmp tarball base
  tmp="$(mktemp -d)"
  tarball="${project}-${version}.linux-amd64.tar.gz"
  base="https://github.com/prometheus/${project}/releases/download/v${version}"
  curl -fsSL -o "${tmp}/${tarball}" "${base}/${tarball}"
  curl -fsSL -o "${tmp}/sha256sums.txt" "${base}/sha256sums.txt"
  (cd "${tmp}" && grep "  ${tarball}\$" sha256sums.txt | sha256sum -c -)
  tar -xzf "${tmp}/${tarball}" -C "${tmp}" "${project}-${version}.linux-amd64/${tool}"
  ${SUDO} install -m 0755 "${tmp}/${project}-${version}.linux-amd64/${tool}" "${BIN_DIR}/${tool}"
  rm -rf "${tmp}"
  echo "${tool} ${version} 설치함 (${BIN_DIR})"
}

mkdir -p "${BIN_DIR}" 2>/dev/null || ${SUDO} mkdir -p "${BIN_DIR}"
install_tool promtool prometheus "${PROMETHEUS_VERSION}"
install_tool amtool alertmanager "${ALERTMANAGER_VERSION}"
