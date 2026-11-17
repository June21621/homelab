# /// script
# requires-python = ">=3.12"
# dependencies = ["pyyaml==6.0.3", "pytest==8.4.2"]
# ///
"""check_rendered.py의 monitoring·apps·argocd 검사 테스트. 작은 가짜 매니페스트로 확인한다.

사용: uv run --script scripts/test_check_rendered.py
"""

import base64
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).parent))
import check_rendered as cr  # noqa: E402

DISCORD_FILE = "/etc/alertmanager/secrets/alertmanager-receivers/discord-webhook-url"
HC_FILE = "/etc/alertmanager/secrets/alertmanager-receivers/healthchecks-ping-url"

RES = {"requests": {"memory": "32Mi"}, "limits": {"memory": "64Mi"}}


def am_config(**over):
    """정상 Alertmanager 설정. over로 일부를 바꾼다."""
    cfg = {
        "route": {
            "receiver": "discord",
            "group_by": ["alertname", "namespace"],
            "routes": [
                {
                    "matchers": ['alertname="Watchdog"'],
                    "receiver": "healthchecks",
                    "group_wait": "0s",
                    "group_interval": "1m",
                    "repeat_interval": "1m",
                },
            ],
        },
        "receivers": [
            {"name": "null"},
            {"name": "discord", "discord_configs": [{"webhook_url_file": DISCORD_FILE, "send_resolved": True}]},
            {"name": "healthchecks", "webhook_configs": [{"url_file": HC_FILE, "send_resolved": False}]},
        ],
    }
    cfg.update(over)
    return cfg


def am_secret(cfg):
    raw = yaml.safe_dump(cfg).encode()
    return {
        "kind": "Secret",
        "metadata": {"name": "alertmanager-monitoring-kube-prometheus-alertmanager"},
        "data": {"alertmanager.yaml": base64.b64encode(raw).decode()},
    }


def good_docs(cfg=None):
    return [
        {"kind": "Prometheus", "metadata": {"name": "monitoring-kube-prometheus-prometheus"},
         "spec": {"retention": "7d", "resources": RES}},
        {"kind": "Alertmanager", "metadata": {"name": "monitoring-kube-prometheus-alertmanager"},
         "spec": {"resources": RES}},
        {"kind": "Deployment", "metadata": {"name": "monitoring-grafana"},
         "spec": {"template": {"spec": {"containers": [{"name": "grafana", "resources": RES}]}}}},
        {"kind": "PrometheusRule", "metadata": {"name": "monitoring-kube-prometheus-node.rules"},
         "spec": {"groups": [{"name": "node.rules", "rules": []}]}},
        am_secret(cfg or am_config()),
    ]


def test_good_monitoring_passes():
    assert cr.check_monitoring(good_docs()) == []


@pytest.mark.parametrize("kind", ["Prometheus", "Alertmanager"])
def test_cr_resources_required(kind):
    docs = good_docs()
    next(d for d in docs if d["kind"] == kind)["spec"].pop("resources")
    errors = cr.check_monitoring(docs)
    assert any(kind in e and "limits.memory" in e for e in errors), errors


def test_cr_sidecar_override_needs_limits():
    docs = good_docs()
    prom = next(d for d in docs if d["kind"] == "Prometheus")
    prom["spec"]["containers"] = [{"name": "config-reloader", "resources": {"requests": {"memory": "16Mi"}}}]
    errors = cr.check_monitoring(docs)
    assert any("config-reloader" in e for e in errors), errors


@pytest.mark.parametrize("name", [
    "monitoring-kube-prometheus-kube-etcd",
    "monitoring-kube-prometheus-kube-scheduler",
    "monitoring-kube-prometheus-kube-controller-manager",
    "monitoring-kube-prometheus-kube-proxy",
])
@pytest.mark.parametrize("kind", ["Service", "ServiceMonitor"])
def test_disabled_scrape_targets(kind, name):
    docs = good_docs() + [{"kind": kind, "metadata": {"name": name}}]
    errors = cr.check_monitoring(docs)
    assert any(name in e for e in errors), errors


@pytest.mark.parametrize("group", [
    "etcd", "kube-scheduler.rules", "kubernetes-system-controller-manager", "kubernetes-system-scheduler",
    "kubernetes-system-kube-proxy", "kube-apiserver-burnrate.rules", "kube-apiserver-histogram.rules",
    "kube-apiserver-slos", "kube-apiserver-availability.rules", "windows.node.rules",
])
def test_disabled_rule_groups(group):
    docs = good_docs() + [{"kind": "PrometheusRule", "metadata": {"name": "x"},
                           "spec": {"groups": [{"name": group, "rules": []}]}}]
    errors = cr.check_monitoring(docs)
    assert any(group in e for e in errors), errors


def test_kept_rule_group_passes():
    docs = good_docs() + [{"kind": "PrometheusRule", "metadata": {"name": "x"},
                           "spec": {"groups": [{"name": "kubernetes-system-apiserver", "rules": []}]}}]
    assert cr.check_monitoring(docs) == []


@pytest.mark.parametrize("receiver", [
    {"name": "discord", "discord_configs": [{"webhook_url": "https://discord.com/api/webhooks/1/x"}]},
    {"name": "healthchecks", "webhook_configs": [{"url": "https://hc-ping.com/uuid"}]},
    {"name": "discord", "discord_configs": [{"webhook_url_file": "/etc/alertmanager/secrets/typo/discord"}]},
    {"name": "healthchecks", "webhook_configs": [{"url_file": "/tmp/hc"}]},
])
def test_alertmanager_urls_only_from_files(receiver):
    cfg = am_config()
    cfg["receivers"] = [r for r in cfg["receivers"] if r["name"] != receiver["name"]] + [receiver]
    errors = cr.check_monitoring(good_docs(cfg))
    assert errors, "URL 리터럴이나 잘못된 파일 경로를 통과시킴"


def test_alertmanager_config_missing():
    docs = [d for d in good_docs() if d["kind"] != "Secret"]
    assert any("alertmanager.yaml" in e for e in cr.check_monitoring(docs))


@pytest.mark.parametrize("key,value", [("group_interval", "5m"), ("repeat_interval", "4h"), ("group_wait", "30s")])
def test_watchdog_route_every_minute(key, value):
    cfg = am_config()
    cfg["route"]["routes"][0][key] = value
    errors = cr.check_monitoring(good_docs(cfg))
    assert any("Watchdog" in e for e in errors), errors


def test_watchdog_route_missing():
    cfg = am_config()
    cfg["route"]["routes"] = []
    assert any("Watchdog" in e for e in cr.check_monitoring(good_docs(cfg)))


def test_retention():
    docs = good_docs()
    next(d for d in docs if d["kind"] == "Prometheus")["spec"]["retention"] = "15d"
    assert any("retention" in e for e in cr.check_monitoring(docs))


def test_monitoring_app_no_finalizer():
    app = {"kind": "Application", "metadata": {"name": "monitoring", "finalizers": [cr.FINALIZER]}}
    assert any("monitoring" in e for e in cr.check_apps([app]))
    app["metadata"].pop("finalizers")
    assert cr.check_apps([app]) == []


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
