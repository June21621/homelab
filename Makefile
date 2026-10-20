# 홈랩 진입점. 관리 PC(WSL)에서 실행한다.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# repo가 Windows 폴더(/mnt/c)에 있어 권한이 어긋나면 Ansible이 ansible.cfg를 무시하므로 경로를 명시한다.
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help workstation hooks lint deps agent host host-check kubeconfig verify-k3s etcd-restore

ANSIBLE := cd ansible && ansible-playbook

help: ## 사용 가능한 명령 목록
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

workstation: ## 관리 PC 도구 설치 (버전 고정)
	bash scripts/bootstrap-workstation.sh

hooks: ## pre-commit 훅 설치
	pre-commit install

lint: ## 전체 파일 검사
	pre-commit run --all-files

deps: ## Ansible 컬렉션 설치 (requirements.yml 버전 고정)
	cd ansible && ansible-galaxy collection install -r requirements.yml

agent: ## SSH 키가 agent에 없으면 1시간 동안 올림 (passphrase 입력)
	@ssh-add -l >/dev/null 2>&1 || ssh-add -t 1h

host: deps agent ## 미니 PC 호스트 구성 적용 (sudo 비밀번호 입력)
	$(ANSIBLE) site.yml --diff

host-check: deps agent ## 바뀔 내용만 미리 보기 (적용 안 함)
	$(ANSIBLE) site.yml --check --diff

kubeconfig: deps agent ## 관리 PC에 kubeconfig 가져오기 (~/.kube/homelab.yaml)
	$(ANSIBLE) kubeconfig.yml

verify-k3s: ## k3s 설치 결과 확인 (노드·파드·DNS·포트)
	bash scripts/verify-k3s.sh

etcd-restore: deps agent ## etcd를 S3 스냅샷으로 복원 (SNAPSHOT=<파일명> 필수, 되돌릴 수 없음)
	@test -n "$(SNAPSHOT)" || { echo "SNAPSHOT=<파일명>을 지정하세요" >&2; exit 1; }
	SNAPSHOT="$(SNAPSHOT)" $(ANSIBLE) etcd-restore.yml
