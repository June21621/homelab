# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3"]
# ///
"""helm template 결과(표준 입력)에서 Alertmanager 설정을 꺼내 amtool check-config용 사본을 만든다.

사용: helm template ... | am_config_for_check.py <출력 폴더>
  <출력 폴더>/alertmanager.yaml 을 쓴다. 설정 안의 *_file 경로(클러스터의 Secret 마운트 위치)는
  <출력 폴더>/secrets/<파일 이름>(빈 파일)로 바꾼다. 실제 비밀값은 다루지 않는다.
  같은 Secret의 *.tmpl(알림 문구 템플릿)은 <출력 폴더>/templates/에 꺼낸다(scripts/test-am-templates.sh가 사용).
설정이 없으면 1.
"""

import base64
import sys
from pathlib import Path

import yaml

FILE_KEYS = ("webhook_url_file", "url_file")


def rewrite_files(node, secrets: Path):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in FILE_KEYS and isinstance(v, str):
                target = secrets / Path(v).name
                target.touch()
                node[k] = str(target)
            else:
                rewrite_files(v, secrets)
    elif isinstance(node, list):
        for v in node:
            rewrite_files(v, secrets)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("사용: am_config_for_check.py <출력 폴더>", file=sys.stderr)
        return 2
    out = Path(argv[1])
    secrets = out / "secrets"
    secrets.mkdir(parents=True, exist_ok=True)
    # 입력을 끝까지 읽는다. 중간에 멈추면 파이프 앞의 helm이 SIGPIPE(141)로 끝난다
    for doc in list(yaml.safe_load_all(sys.stdin)):
        if doc and doc.get("kind") == "Secret" and "alertmanager.yaml" in (doc.get("data") or {}):
            data = doc["data"]
            cfg = yaml.safe_load(base64.b64decode(data["alertmanager.yaml"]))
            rewrite_files(cfg, secrets)
            # 템플릿(alertmanager.templateFiles)은 같은 Secret의 *.tmpl 키. 클러스터 안 경로(/etc/alertmanager/config)
            # 대신 <출력 폴더>/templates/에 꺼내 두고, 설정도 그 경로를 보게 한다(amtool check-config가 템플릿 문법까지 검사)
            templates = out / "templates"
            templates.mkdir(exist_ok=True)
            for key, val in data.items():
                if key.endswith(".tmpl"):
                    (templates / key).write_bytes(base64.b64decode(val))
            cfg["templates"] = [str(templates / "*.tmpl")]
            (out / "alertmanager.yaml").write_text(yaml.safe_dump(cfg, allow_unicode=True), encoding="utf-8")
            return 0
    print("alertmanager.yaml을 담은 Secret이 없음")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
