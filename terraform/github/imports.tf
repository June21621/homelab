# 이미 있는 repo를 Terraform 관리로 가져온다 (새로 만들지 않는다)
import {
  to = github_repository.homelab
  id = "homelab"
}

import {
  to = github_actions_repository_permissions.homelab
  id = "homelab"
}

import {
  to = github_workflow_repository_permissions.homelab
  id = "homelab"
}
