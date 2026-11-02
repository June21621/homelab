# 홈랩 진입점. 관리 PC(WSL)에서 실행한다.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# repo가 Windows 폴더(/mnt/c)에 있어 권한이 어긋나면 Ansible이 ansible.cfg를 무시하므로 경로를 명시한다.
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help workstation hooks lint deps agent host host-check kubeconfig verify-k3s etcd-restore \
	argocd-bootstrap verify-argocd argocd-ui

ANSIBLE := cd ansible && ansible-playbook
TF_ARGOCD := terraform -chdir=terraform/argocd-bootstrap
AWS_TFSTATE_PROFILE := homelab-tfstate

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

argocd-bootstrap: ## ArgoCD 첫 설치 (Terraform, 재구축 때만. SSO 로그인 필요)
	@# WSL은 브라우저를 직접 못 열어서 코드 입력 방식으로 로그인한다
	@aws sts get-caller-identity --profile $(AWS_TFSTATE_PROFILE) >/dev/null 2>&1 || aws sso login --profile $(AWS_TFSTATE_PROFILE) --use-device-code
	$(TF_ARGOCD) init -input=false
	$(TF_ARGOCD) apply

verify-argocd: ## ArgoCD 확인: 모든 Application이 Synced·Healthy (STATIC=1이면 repo 파일만 검사)
	bash scripts/verify-argocd.sh $(if $(STATIC),--static)

argocd-ui: ## ArgoCD 웹 UI 터널 (출력된 주소를 Windows 브라우저에서 열기, Ctrl+C로 종료)
	@# 이 PC는 WSL의 localhost가 Windows로 전달되지 않아 WSL 가상 NIC 주소에도 연다(LAN에서는 안 보임)
	@ip="$$(hostname -I | awk '{print $$1}')"; \
	echo "Windows 브라우저: https://$${ip}:8080   (WSL 안: https://localhost:8080)"; \
	KUBECONFIG=$(HOME)/.kube/homelab.yaml kubectl -n argocd port-forward --address "127.0.0.1,$${ip}" svc/argocd-server 8080:443
