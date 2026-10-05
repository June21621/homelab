# 홈랩 진입점. 관리 PC(WSL)에서 실행한다.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# repo가 Windows 폴더(/mnt/c)에 있어 권한이 어긋나면 Ansible이 ansible.cfg를 무시하므로 경로를 명시한다.
export ANSIBLE_CONFIG := $(CURDIR)/ansible/ansible.cfg

.PHONY: help workstation hooks lint

help: ## 사용 가능한 명령 목록
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  %-14s %s\n", $$1, $$2}'

workstation: ## 관리 PC 도구 설치 (버전 고정)
	bash scripts/bootstrap-workstation.sh

hooks: ## pre-commit 훅 설치
	pre-commit install

lint: ## 전체 파일 검사
	pre-commit run --all-files
