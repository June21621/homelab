# homelab repo 설정과 main 보호 규칙.
# 값은 import 당시 설정을 그대로 옮겼고, 의도해서 바꾼 것만 주석으로 표시한다.
resource "github_repository" "homelab" {
  name       = "homelab"
  visibility = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = false
  has_discussions = false
  is_template     = false

  allow_merge_commit          = true
  allow_squash_merge          = true
  allow_rebase_merge          = true
  allow_update_branch         = false
  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"
  web_commit_signoff_required = false

  allow_auto_merge       = true # 변경: 검사를 통과한 태그 PR 자동 병합
  delete_branch_on_merge = true # 변경: 병합된 bump/* 브랜치 자동 삭제

  # 변경: public repo는 무료. 비밀값이 push되면 GitHub이 push 자체를 막는다 (gitleaks와 이중 방어)
  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }

  # Terraform 실수로 repo가 지워지면 안 된다
  lifecycle {
    prevent_destroy = true
  }
}

# main 보호. 우회(bypass) 계정은 두지 않는다 — 관리자도 PR과 검사를 거친다.
# 비상시에는 이 리소스의 enforcement를 "disabled"로 바꿔 apply한다.
resource "github_repository_ruleset" "main" {
  name        = "main"
  repository  = github_repository.homelab.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true # main 삭제 금지
    non_fast_forward = true # 강제 push 금지

    # 직접 push 금지, PR로만. 혼자 쓰는 repo라 승인 수는 0 (본인 PR은 본인이 승인할 수 없다)
    pull_request {
      required_approving_review_count = 0
    }

    required_status_checks {
      required_check {
        context        = "tag-pr-guard"
        integration_id = 15368 # GitHub Actions. 다른 앱이 같은 이름으로 성공을 보고해도 인정하지 않는다
      }
      required_check {
        context        = "static-checks"
        integration_id = 15368
      }
      # true면 main이 앞서 나갈 때마다 PR을 갱신해야 해서 태그 PR 자동 병합이 멈춘다
      strict_required_status_checks_policy = false
    }
  }
}
