#!/usr/bin/env python3
"""Deterministic, read-only contract guard for hkstock AI-native research."""

import datetime as dt
import json
import os
from pathlib import Path
import re
import sys
from urllib.parse import urlparse

WORKFLOW_ID = "hkstock-ai-native-v1"
PROVIDERS = {"Wind", "同花顺 iFinD", "Sina", "Eastmoney", "AkShare", "CNINFO", "HKEXnews", "Media"}
PROVENANCE = {"披露", "测算", "预期", "推断", "媒体"}
ACTIONS = {"买入", "加仓", "持有", "减仓", "清仓", "观望", "不判断"}
EVIDENCE_FIELDS = {
    "schema_version": int, "id": str, "subject": str, "asset_type": str,
    "provider": str, "route": str, "tool": str, "query": dict,
    "report_period": (str, type(None)), "announcement_date": (str, type(None)),
    "currency": (str, type(None)), "unit": (str, type(None)),
    "source_url": (str, type(None)), "page": (int, type(None)),
    "source_version": (str, type(None)), "supersedes": (str, type(None)),
    "retrieved_at": str, "provenance": str, "raw_response": (dict, list),
}
REQUIRED_BRIEF_COLUMNS = {"标的", "行动", "仓位建议", "教学式原因", "改变观点的条件", "证据"}
REQUIRED_THESIS_SECTIONS = {"当前观点", "关键假设", "反证与风险", "证据", "观点历史"}
AUTH_KEYS = {"authorization", "access_token", "refresh_token", "api_key", "apikey", "token", "secret", "password", "cookie", "x_bigmodel_authorization", "private_key", "credential", "credentials"}
AUTH_SUFFIXES = ("authorization", "accesstoken", "refreshtoken", "sessiontoken", "authtoken", "jwttoken", "apikey", "privatekey", "credential", "credentials", "secret", "password", "cookie", "token")


def normalize_auth_key(key):
    return re.sub(r"[^a-z0-9]", "", str(key or "").lower())


def data_root():
    if os.environ.get("HKSTOCK_DATA_DIR"):
        return Path(os.environ["HKSTOCK_DATA_DIR"])
    return Path(os.environ.get("MARTIN_ROOT", "/Users/stringzhao/workspace/martin")) / "hkstock-data"


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def frontmatter(text):
    if not text.startswith("---\n"):
        return {}, text
    match = re.match(r"\A---\n(.*?)\n---\s*\n?", text, re.S)
    if not match:
        return {}, text
    data = {}
    for line in match.group(1).splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        data[key.strip()] = value
    return data, text[match.end():]


def sections(text):
    matches = list(re.finditer(r"(?m)^##\s+([^\n]+?)\s*$", text))
    return {m.group(1).strip(): text[m.end():matches[i + 1].start() if i + 1 < len(matches) else len(text)] for i, m in enumerate(matches)}


def anchors(text):
    return re.findall(r"\[(E[A-Za-z0-9_-]+)\]", text)


def parse_rfc3339(value):
    if not isinstance(value, str) or "T" not in value:
        return False
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.tzinfo is not None
    except ValueError:
        return False


def parse_date(value):
    try:
        return dt.date.fromisoformat(value)
    except (TypeError, ValueError):
        return None


def contains_auth(value, key=None):
    normalized = normalize_auth_key(key)
    normalized_exact = {normalize_auth_key(item) for item in AUTH_KEYS}
    if normalized in normalized_exact or normalized.endswith(AUTH_SUFFIXES):
        return True
    if isinstance(value, dict):
        return any(contains_auth(v, k) for k, v in value.items())
    if isinstance(value, list):
        return any(contains_auth(v) for v in value)
    if isinstance(value, str):
        return bool(re.search(r"Bearer\s+\S+|enc:v1:[^\s\"']+", value, re.I))
    return False


def is_vendor_homepage(value):
    if not isinstance(value, str):
        return False
    parsed = urlparse(value)
    vendor_hosts = {
        "wind.com.cn", "www.wind.com.cn", "10jqka.com.cn", "www.10jqka.com.cn",
        "eastmoney.com", "www.eastmoney.com", "akshare.akfamily.xyz",
        "cninfo.com.cn", "www.cninfo.com.cn", "sina.com.cn", "www.sina.com.cn",
        "finance.sina.com.cn", "hkexnews.hk", "www.hkexnews.hk", "www1.hkexnews.hk",
    }
    return parsed.hostname in vendor_hosts and parsed.path in {"", "/", "/index.html", "/index.htm", "/index.php"}


def evidence_paths(path):
    if path.is_file():
        return [path], sorted(path.parent.glob("*.json"))
    if path.is_dir():
        paths = sorted(path.rglob("*.json"))
        return paths, paths
    raise ValueError("path does not exist")


def load_json(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def validate_evidence_file(path, obj):
    errors = []
    if not isinstance(obj, dict):
        return ["evidence must be a JSON object"]
    for field, expected in EVIDENCE_FIELDS.items():
        if field not in obj:
            errors.append(f"missing field {field}")
        elif not isinstance(obj[field], expected) or (expected is int and not _is_int(obj[field])):
            errors.append(f"invalid type for {field}")
        if field == "page" and field in obj and obj[field] is not None and not _is_int(obj[field]):
            errors.append("page must be an integer or null")
    if errors:
        return errors
    if obj["schema_version"] != 1:
        errors.append("schema_version must be 1")
    if not re.fullmatch(r"E[A-Za-z0-9_-]+", obj["id"]):
        errors.append("invalid evidence id")
    if path.stem != obj["id"]:
        errors.append("evidence filename must be <id>.json")
    for field in ("id", "subject", "route", "tool"):
        if not obj[field].strip():
            errors.append(f"{field} cannot be empty")
    if obj["asset_type"] not in {"stock", "fund"}:
        errors.append("invalid asset_type")
    if obj["provider"] not in PROVIDERS:
        errors.append("invalid provider")
    if obj["provenance"] not in PROVENANCE:
        errors.append("invalid provenance")
    if obj["provider"] == "Media" and (obj["provenance"] != "媒体" or not obj["source_url"]):
        errors.append("Media requires provenance=媒体 and a specific source_url")
    if obj["page"] is not None and obj["page"] < 1:
        errors.append("page must be >= 1")
    if not parse_rfc3339(obj["retrieved_at"]):
        errors.append("retrieved_at must be RFC 3339 with timezone")
    if obj["announcement_date"] is not None and parse_date(obj["announcement_date"]) is None:
        errors.append("announcement_date must be YYYY-MM-DD or null")
    if obj["source_url"] is not None and not re.match(r"https?://", obj["source_url"]):
        errors.append("source_url must be an HTTP(S) URL or null")
    if is_vendor_homepage(obj["source_url"]):
        errors.append("source_url must locate a specific record, not a vendor homepage")
    if (obj["route"] == "finance_wind_docs" or obj["provider"] in {"CNINFO", "HKEXnews"}) and not obj["source_version"]:
        errors.append("document evidence requires source_version")
    if obj["supersedes"] is not None and not re.fullmatch(r"E[A-Za-z0-9_-]+", obj["supersedes"]):
        errors.append("invalid supersedes id")
    if contains_auth(obj):
        errors.append("authentication material is forbidden")
    return errors


def validate_evidence(path):
    errors = []
    try:
        selected, context_paths = evidence_paths(path)
    except ValueError as exc:
        return {}, [str(exc)]
    if not selected:
        return {}, ["no JSON evidence files found"]
    records = {}
    for item in context_paths:
        try:
            obj = load_json(item)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            if item in selected:
                errors.append(f"{item.name}: invalid JSON: {exc}")
            continue
        item_errors = validate_evidence_file(item, obj)
        if item in selected:
            errors.extend(f"{item.name}: {error}" for error in item_errors)
        if isinstance(obj, dict) and isinstance(obj.get("id"), str):
            records[obj["id"]] = obj
    for obj in records.values():
        seen = set()
        current = obj
        while current.get("supersedes") if isinstance(current, dict) else False:
            parent_id = current["supersedes"]
            if parent_id not in records:
                errors.append(f"{current.get('id')}: supersedes missing {parent_id}")
                break
            if current["id"] in seen or parent_id == current["id"]:
                errors.append(f"{current.get('id')}: cyclic supersedes chain")
                break
            seen.add(current["id"])
            current = records[parent_id]
            if current is obj:
                errors.append(f"{obj['id']}: cyclic supersedes chain")
                break
    return records, sorted(set(errors))


def evidence_context():
    root = data_root()
    records, errors = validate_evidence(root / "evidence")
    successors = {obj["supersedes"]: obj["id"] for obj in records.values() if isinstance(obj, dict) and obj.get("supersedes")}
    return root, records, successors, errors


def check_anchor_closure(text, records, successors=None, require_latest=False, label="document"):
    errors = []
    for evidence_id in sorted(set(anchors(text))):
        if evidence_id not in records:
            errors.append(f"{label}: missing local evidence {evidence_id}")
        elif require_latest and evidence_id in (successors or {}):
            errors.append(f"{label}: superseded evidence {evidence_id}; use {successors[evidence_id]}")
    return errors


def check_product_meta(meta, errors):
    if meta.get("workflow_id") != WORKFLOW_ID:
        errors.append(f"workflow_id must be {WORKFLOW_ID}")
    if not str(meta.get("report_id", "")).strip():
        errors.append("report_id is required")


def check_unique_report(path, meta):
    report_id = meta.get("report_id")
    if not report_id:
        return []
    errors = []
    root = data_root()
    candidates = root.rglob("*.md") if root.is_dir() else path.parent.glob("*.md")
    for other in candidates:
        if other.resolve() == path.resolve():
            continue
        try:
            other_meta, _ = frontmatter(other.read_text(encoding="utf-8"))
        except (OSError, UnicodeError):
            continue
        if other_meta.get("report_id") == report_id:
            errors.append(f"duplicate report_id {report_id} across data root: {other}")
    return sorted(set(errors))


def check_unique_event(path, meta):
    event_id = meta.get("event_id")
    if not event_id:
        return []
    errors = []
    root = data_root()
    candidates = root.rglob("*.md") if root.is_dir() else path.parent.glob("*.md")
    for other in candidates:
        if other.resolve() == path.resolve():
            continue
        try:
            other_meta, _ = frontmatter(other.read_text(encoding="utf-8"))
        except (OSError, UnicodeError):
            continue
        if other_meta.get("event_id") == event_id:
            errors.append(f"duplicate event_id {event_id} across data root: {other}")
    return sorted(set(errors))


def opinion_rows(section):
    lines = [line for line in section.splitlines() if line.strip().startswith("|")]
    if len(lines) < 2:
        return [], []
    def cells(line):
        return [cell.strip() for cell in line.strip().strip("|").split("|")]
    headers = cells(lines[0])
    rows = []
    for line in lines[2:]:
        values = cells(line)
        if len(values) == len(headers):
            rows.append(dict(zip(headers, values)))
    return headers, rows


def resolve_link(source, target):
    clean = target.split("#", 1)[0].strip()
    return Path(clean) if clean.startswith("/") else (source.parent / clean).resolve()


def markdown_links(text):
    return re.findall(r"\[[^\]]+\]\(([^)]+\.md)(?:#[^)]*)?\)", text)


def validate_event(path, records, successors):
    errors = []
    try:
        meta, body = frontmatter(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        return [f"event {path}: {exc}"]
    check_product_meta(meta, errors)
    if not str(meta.get("event_id", "")).strip():
        errors.append("event_id is required")
    errors.extend(check_unique_report(path, meta))
    body_sections = sections(body)
    if "事件影响" not in body_sections:
        errors.append("missing section ## 事件影响")
    markers = ("行动：", "教学式原因：", "触发条件：", "仓位建议：", "证据：")
    if all(marker in body for marker in markers):
        action = re.search(r"行动：\s*([^\n]+)", body).group(1).strip()
        if action not in ACTIONS:
            errors.append(f"event invalid action {action}")
    else:
        headers, rows = opinion_rows(body)
        required = {"标的", "行动", "仓位建议", "教学式原因", "证据"}
        has_trigger = "改变观点的条件" in headers or "触发条件" in headers
        if not rows or required - set(headers) or not has_trigger:
            errors.append("event requires action, teaching reason, trigger, position advice and evidence")
        for row in rows:
            if row.get("行动") not in ACTIONS:
                errors.append(f"event invalid action {row.get('行动')}")
    if not anchors(body):
        errors.append("event requires at least one evidence anchor")
    errors.extend(check_anchor_closure(body, records, successors, True, "event"))
    thesis_links = [link for link in markdown_links(body) if "thesis" in link.lower() or "theses" in link.lower()]
    if not thesis_links:
        errors.append("event requires a thesis link")
    for link in thesis_links:
        target = resolve_link(path, link)
        if not target.is_file():
            errors.append(f"event thesis link does not exist: {link}")
        else:
            errors.extend(validate_thesis(target, records, successors, check_meta=True))
    errors.extend(check_unique_event(path, meta))
    return errors


def validate_brief(path):
    errors = []
    root, records, successors, evidence_errors = evidence_context()
    errors.extend(evidence_errors)
    try:
        meta, body = frontmatter(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        return [str(exc)]
    check_product_meta(meta, errors)
    errors.extend(check_unique_report(path, meta))
    body_sections = sections(body)
    for name in ("组合观点", "证据与数据缺口"):
        if name not in body_sections:
            errors.append(f"missing section ## {name}")
    if errors:
        return errors
    opinion_section = body_sections["组合观点"]
    gap_section = body_sections["证据与数据缺口"]
    headers, rows = opinion_rows(opinion_section)
    missing_columns = REQUIRED_BRIEF_COLUMNS - set(headers)
    if missing_columns:
        errors.append(f"opinion table missing columns: {','.join(sorted(missing_columns))}")
    if not rows:
        errors.append("opinion table has no rows")
    for row in rows:
        subject = row.get("标的", "")
        action = row.get("行动", "")
        position = row.get("仓位建议", "")
        row_text = " ".join(row.values())
        if action not in ACTIONS:
            errors.append(f"{subject}: invalid action {action}")
        if action != "不判断" and not anchors(row.get("证据", "")):
            errors.append(f"{subject}: non-不判断 opinion requires evidence")
        if action != "不判断" and re.search(r"证据不足|证据冲突|无法调和|冲突未解|数据不足", row_text):
            errors.append(f"{subject}: insufficient/conflicting evidence requires 不判断")
        identifiers = [value for value in [subject, *subject.split()] if len(value) >= 4]
        for line in gap_section.splitlines():
            if re.search(r"证据不足|证据冲突|无法调和|冲突未解|数据不足", line) and any(value in line for value in identifiers) and action != "不判断":
                errors.append(f"{subject}: gap section declares unresolved evidence conflict")
        if action == "不判断":
            if position != "待补证据":
                errors.append(f"{subject}: 不判断 position must be 待补证据")
            if subject not in gap_section or not re.search(r"缺失|不足|冲突|待补|无法调和", gap_section):
                errors.append(f"{subject}: gap section must list its missing/conflicting evidence")
        exact_amount = re.search(r"(?:CNY|HKD|USD|¥|￥)\s*\d|\d+(?:\.\d+)?\s*(?:元|万元|亿元|港元|美元)", position, re.I)
        if exact_amount and str(meta.get("portfolio_complete", "false")).lower() not in {"1", "true", "yes"}:
            errors.append(f"{subject}: exact monetary amount requires complete holdings/cash/risk budget")
    errors.extend(check_anchor_closure(body, records, successors, True, "brief"))
    if re.search(r"全部(?:数据)?源不可用|所有数据源(?:均|都)?不可用|全源失败", body) and any(row.get("行动") != "不判断" for row in rows):
        errors.append("all-source failure cannot produce deterministic opinions")
    if "降级" in body:
        if "降级" not in gap_section or "原因" not in gap_section or not any(provider in gap_section for provider in PROVIDERS):
            errors.append("fallback requires actual provider and reason in gap section")
    referenced = {anchor for anchor in anchors(body) if anchor in records}
    if any(records[evidence_id].get("asset_type") == "fund" for evidence_id in referenced):
        if "持仓穿透" not in body or "重叠" not in body:
            errors.append("fund research requires 持仓穿透 and 重叠 analysis")
    for link in markdown_links(opinion_section + "\n" + gap_section):
        target = resolve_link(path, link)
        if not target.is_file():
            errors.append(f"deep-research link does not exist: {link}")
            continue
        target_meta, _ = frontmatter(target.read_text(encoding="utf-8"))
        if "events" in target.parts or target_meta.get("event_id"):
            errors.extend(validate_event(target, records, successors))
    return sorted(set(errors))


def validate_thesis(path, records=None, successors=None, check_meta=True):
    errors = []
    if records is None or successors is None:
        _, records, successors, evidence_errors = evidence_context()
        errors.extend(evidence_errors)
    try:
        meta, body = frontmatter(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        return [f"{path.name}: {exc}"]
    if check_meta:
        check_product_meta(meta, errors)
        errors.extend(check_unique_report(path, meta))
    if not str(meta.get("subject", "")).strip():
        errors.append(f"{path.name}: subject is required")
    try:
        revision = int(meta.get("revision", ""))
        if revision < 1 or str(revision) != str(meta.get("revision")):
            raise ValueError
    except ValueError:
        errors.append(f"{path.name}: revision must be an integer >= 1")
        revision = None
    if not parse_rfc3339(meta.get("updated_at")):
        errors.append(f"{path.name}: updated_at must be RFC 3339")
    if parse_date(meta.get("review_after")) is None:
        errors.append(f"{path.name}: review_after must be YYYY-MM-DD")
    body_sections = sections(body)
    missing = REQUIRED_THESIS_SECTIONS - set(body_sections)
    if missing:
        errors.append(f"{path.name}: missing thesis sections {','.join(sorted(missing))}")
        return errors
    current_text = "\n".join(body_sections[name] for name in REQUIRED_THESIS_SECTIONS if name != "观点历史")
    errors.extend(check_anchor_closure(current_text, records, successors, True, f"thesis {path.name} current view"))
    if not anchors(body_sections["证据"]):
        errors.append(f"{path.name}: ## 证据 requires at least one anchor")
    history = body_sections["观点历史"]
    matches = list(re.finditer(r"(?m)^###\s+revision\s+(\d+)\s*$", history))
    if not matches:
        errors.append(f"{path.name}: 观点历史 requires revision entries")
    revisions = []
    for index, match in enumerate(matches):
        number = int(match.group(1)); revisions.append(number)
        block = history[match.end():matches[index + 1].start() if index + 1 < len(matches) else len(history)]
        if not re.search(r"(?m)^\s*[-*]?\s*revision\s*:\s*\d+", block):
            errors.append(f"{path.name}: history revision {number} missing revision field")
        if "当时证据" not in block or not anchors(block):
            errors.append(f"{path.name}: history revision {number} missing 当时证据")
        if "触发条件" not in block:
            errors.append(f"{path.name}: history revision {number} missing 触发条件")
        errors.extend(check_anchor_closure(block, records, {}, False, f"thesis {path.name} history"))
    if revisions != sorted(set(revisions)):
        errors.append(f"{path.name}: history revisions must be strictly increasing")
    if revision is not None and revisions and revisions[-1] != revision:
        errors.append(f"{path.name}: latest history revision must equal frontmatter revision")
    return sorted(set(errors))


def validate_review(path):
    errors = []
    root, records, successors, evidence_errors = evidence_context()
    errors.extend(evidence_errors)
    try:
        meta, body = frontmatter(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        return [str(exc)]
    check_product_meta(meta, errors)
    errors.extend(check_unique_report(path, meta))
    body_sections = sections(body)
    review_section = body_sections.get("到期复盘", "")
    headers, rows = opinion_rows(review_section)
    required = {"标的", "结论", "原假设", "新增证据变化"}
    if required - set(headers) or not rows:
        errors.append("review requires a 到期复盘 table with 标的/结论/原假设/新增证据变化")
    reviewed = {}
    for row in rows:
        subject = row.get("标的", "")
        verdict = row.get("结论", "")
        assumption = row.get("原假设", "")
        evidence_change = row.get("新增证据变化", "")
        if not subject or subject in reviewed:
            errors.append(f"review subject missing or duplicated: {subject}")
        reviewed[subject] = row
        if verdict not in {"验证", "证伪", "待观察"}:
            errors.append(f"{subject}: invalid review verdict {verdict}")
        if not assumption:
            errors.append(f"{subject}: 原假设 is required")
        if not anchors(evidence_change):
            errors.append(f"{subject}: 新增证据变化 requires a traceable evidence anchor")
        if verdict in {"验证", "证伪"} and re.search(r"无新增|没有新增|尚无新增|未新增", evidence_change):
            errors.append(f"{subject}: {verdict} requires new supporting or challenging evidence")
    for line in body.splitlines():
        if re.search(r"T\s*\+\s*(?:1|5|20)|命中率", line, re.I) and not re.search(r"辅助|不作为|不再|禁止", line):
            errors.append("short-term price hit rate cannot be the review criterion")
    errors.extend(check_anchor_closure(body, records, successors, True, "review"))
    review_date = parse_date(meta.get("review_date")) or dt.date.today()
    thesis_dir = root / "theses"
    for thesis_path in sorted(thesis_dir.glob("*.md")) if thesis_dir.is_dir() else []:
        thesis_meta, _ = frontmatter(thesis_path.read_text(encoding="utf-8"))
        due = parse_date(thesis_meta.get("review_after"))
        subject = thesis_meta.get("subject")
        if due and due <= review_date and subject and subject not in reviewed:
            errors.append(f"due thesis not reviewed: {subject}")
    return sorted(set(errors))


def validate_audit():
    audit_path = os.environ.get("HKSTOCK_AUDIT_LOG")
    run_id = os.environ.get("HKSTOCK_RUN_ID")
    if not audit_path and not run_id:
        return []
    if not audit_path or not run_id:
        return ["HKSTOCK_AUDIT_LOG and HKSTOCK_RUN_ID must be set together"]
    try:
        lines = Path(audit_path).read_text(encoding="utf-8").splitlines()
        events = [json.loads(line) for line in lines if line.strip()]
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        return [f"invalid side-effect audit: {exc}"]
    current = [event for event in events if isinstance(event, dict) and event.get("run_id") == run_id]
    if not events or not current:
        return ["side-effect audit must be non-empty and cover this run"]
    if not any(event.get("action") == "process_start" for event in current):
        return ["side-effect audit requires a real process_start event"]
    errors = []
    evidence_root = data_root() / "evidence"
    for event in current:
        action = str(event.get("action", "")).lower()
        target = str(event.get("target", "")).replace("\\", "/")
        if re.search(r"broker|place_?order|cancel_?order|trade_?execut|withdraw|(?:^|_)(?:trade|order|buy|sell|cancel)(?:_|$)", action):
            errors.append(f"forbidden trading side effect: {action}")
        if re.search(r"(?:^|/)out/a-share-", target) and action in {"write", "append", "delete", "move", "rename"}:
            errors.append(f"forbidden legacy ledger write: {target}")
        if action in {"provider_modify", "provider_modification", "model_modify", "model_modification"}:
            errors.append("provider/model modification is forbidden")
        if action in {"history_delete", "legacy_ledger_write"} or (action in {"delete", "move", "rename"} and re.search(r"signals\.jsonl|out/a-share-", target)):
            errors.append(f"historical ledger deletion/rewrite is forbidden: {target}")
        if action in {"wechat_send", "unapproved_wechat", "external_push"} and event.get("approved") is not True:
            errors.append("unapproved WeChat/external push is forbidden")
        if action in {"evidence_write", "evidence_outside_gitignore"}:
            try:
                Path(target).resolve().relative_to(evidence_root.resolve())
            except (ValueError, OSError):
                errors.append("evidence writes must stay inside HKSTOCK_DATA_DIR/evidence")
        for field in ("detail", "content", "command"):
            value = event.get(field)
            if isinstance(value, str) and re.search(r"Bearer\s+\S+|enc:v1:[^\s\"']+", value, re.I):
                errors.append("token material in audit event is forbidden")
        if action in {"write", "append", "evidence_write", "token_write"} and target:
            target_path = Path(target)
            if action == "token_write":
                errors.append("token material on disk is forbidden")
            elif target_path.is_file():
                try:
                    text = target_path.read_text(encoding="utf-8", errors="replace")
                    if re.search(r"Bearer\s+\S+|enc:v1:[^\s\"']+", text, re.I):
                        errors.append("token material in written file is forbidden")
                except OSError as exc:
                    errors.append(f"cannot audit written file: {exc}")
    return sorted(set(errors))


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 2 or argv[0] not in {"evidence", "brief", "thesis", "review"}:
        print("USAGE_ERROR expected: research_guard.py evidence|brief|thesis|review <FILE_OR_DIR>", file=sys.stderr)
        return 2
    mode, raw_path = argv
    path = Path(raw_path)
    if not path.exists():
        print(f"USAGE_ERROR path does not exist: {path}", file=sys.stderr)
        return 2
    try:
        if mode == "evidence":
            _, errors = validate_evidence(path)
        elif mode == "brief":
            if not path.is_file():
                raise ValueError("brief mode requires a file")
            errors = validate_brief(path)
        elif mode == "thesis":
            paths = [path] if path.is_file() else sorted(path.rglob("*.md"))
            if not paths:
                raise ValueError("no thesis Markdown files found")
            _, records, successors, errors = evidence_context()
            for item in paths:
                item_meta, item_body = frontmatter(item.read_text(encoding="utf-8"))
                if item_meta.get("event_id") or re.search(r"(?m)^##\s+事件影响\s*$", item_body):
                    errors.extend(validate_event(item, records, successors))
                else:
                    errors.extend(validate_thesis(item, records, successors))
        else:
            if not path.is_file():
                raise ValueError("review mode requires a file")
            errors = validate_review(path)
        errors.extend(validate_audit())
    except (OSError, UnicodeError, ValueError) as exc:
        print(f"USAGE_ERROR {exc}", file=sys.stderr)
        return 2
    if errors:
        print(f"FAIL {mode} {path} -- {'；'.join(dict.fromkeys(errors))}", file=sys.stderr)
        return 1
    print(f"PASS {mode} {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
