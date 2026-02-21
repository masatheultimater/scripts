"""学習効率向上ロジック（頻度・弱点フォーカス・ダッシュボード集計）。"""

from __future__ import annotations

from datetime import date, datetime

from lib.houjinzei_common import INTERVAL_DAYS, to_int
from lib.topic_normalize import PARENT_CATEGORIES, get_parent_category

IMPORTANCE_TO_FREQUENCY = {"A": 3, "B": 2, "C": 1}
FOCUS_HOURS = 24
FOCUS_REASON = "wrong>=2"


def clamp(v: float, lo: float, hi: float) -> float:
    return min(max(v, lo), hi)


def get_frequency_score(importance: str) -> int:
    return IMPORTANCE_TO_FREQUENCY.get(str(importance or "").strip(), 1)


def parse_dt_or_none(raw: str | datetime | date | None) -> datetime | None:
    if raw is None:
        return None
    if isinstance(raw, datetime):
        return raw
    if isinstance(raw, date):
        return datetime.combine(raw, datetime.min.time())

    text = str(raw).strip()
    if not text:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            dt = datetime.strptime(text, fmt)
            if fmt == "%Y-%m-%d":
                return datetime.combine(dt.date(), datetime.min.time())
            return dt
        except ValueError:
            continue
    return None


def is_focus_active(focus_until_at: str | datetime | date | None, now: datetime) -> bool:
    until_dt = parse_dt_or_none(focus_until_at)
    return bool(until_dt and now < until_dt)


def _extract_overdue_days(record: dict, now: datetime) -> int:
    if "overdue_days" in record:
        return max(to_int(record.get("overdue_days", 0)), 0)

    last_dt = parse_dt_or_none(record.get("last_practiced"))
    if not last_dt:
        return 0
    idx = to_int(record.get("interval_index", 0))
    if idx < 0:
        return 0
    required = INTERVAL_DAYS[min(idx, len(INTERVAL_DAYS) - 1)]
    return max((now.date() - last_dt.date()).days - required, 0)


def calc_priority_score(record: dict, bucket: float, now: datetime) -> int:
    # バケット優先（小さいほど高優先）を最大ウェイトに置く。
    bucket_rank = max(0, 100 - int(bucket * 10))
    freq = to_int(record.get("frequency_score", get_frequency_score(record.get("importance", ""))))
    wrong_gap = max(to_int(record.get("calc_wrong", 0)) - to_int(record.get("calc_correct", 0)), 0)
    overdue_days = _extract_overdue_days(record, now)
    return bucket_rank * 1_000_000_000 + freq * 1_000_000 + wrong_gap * 1_000 + overdue_days


def estimate_topic_graduation_probability(record: dict, now: datetime) -> float:
    if str(record.get("status", "")).strip() == "卒業":
        return 1.0

    idx = max(0, to_int(record.get("interval_index", 0)))
    base_by_interval = [0.10, 0.30, 0.50, 0.70, 0.90]
    base = base_by_interval[min(idx, 4)]

    correct = to_int(record.get("calc_correct", 0))
    wrong = to_int(record.get("calc_wrong", 0))
    attempts = correct + wrong
    topic_accuracy = (correct / attempts) if attempts > 0 else 0.5
    accuracy_adj = clamp((topic_accuracy - 0.70) * 0.50, -0.20, 0.20)

    focus_active = is_focus_active(record.get("focus_until_at"), now) or bool(
        (record.get("weak_focus") or {}).get("active")
    )
    focus_penalty = 0.20 if focus_active else 0.0
    return clamp(base + accuracy_adj - focus_penalty, 0.05, 0.95)


def build_category_dashboard(records: list[dict], generated_at: datetime) -> dict:
    now = generated_at
    stage_keys = ("未着手", "学習中", "復習中", "卒業済")

    category_buckets = {
        name: {
            "name": name,
            "total_topics": 0,
            "stage_counts": {k: 0 for k in stage_keys},
            "progress_rate": 0.0,
            "accuracy": 0.0,
            "graduation_probability": 0.0,
            "focus_active_topics": 0,
            "frequency_weight_sum": 0,
            "updated_at": now.strftime("%Y-%m-%dT%H:%M:%S"),
            "_attempts": 0,
            "_correct": 0,
            "_weighted_p_sum": 0.0,
        }
        for name in PARENT_CATEGORIES
    }

    total_attempts = 0
    total_correct = 0
    attempted_topics = 0
    graduated_topics = 0

    for r in records:
        category = str(r.get("category", "")).strip() or get_parent_category(str(r.get("topic_name", "")).strip())
        if category not in category_buckets:
            category = get_parent_category(category)
        bucket = category_buckets.get(category) or category_buckets["その他"]

        status = str(r.get("status", "")).strip()
        stage = str(r.get("stage", "")).strip()
        if stage not in stage_keys:
            stage = "卒業済" if status == "卒業" else "未着手"

        correct = to_int(r.get("calc_correct", 0))
        wrong = to_int(r.get("calc_wrong", 0))
        attempts = correct + wrong
        if attempts > 0 or to_int(r.get("kome_total", 0)) > 0:
            attempted_topics += 1
        if status == "卒業":
            graduated_topics += 1

        freq = to_int(r.get("frequency_score", get_frequency_score(r.get("importance", ""))))
        focus_active = is_focus_active(r.get("focus_until_at"), now)
        p = estimate_topic_graduation_probability(r, now)

        bucket["total_topics"] += 1
        bucket["stage_counts"][stage] += 1
        bucket["_attempts"] += attempts
        bucket["_correct"] += correct
        bucket["_weighted_p_sum"] += p * freq
        bucket["frequency_weight_sum"] += freq
        if focus_active:
            bucket["focus_active_topics"] += 1

        total_attempts += attempts
        total_correct += correct

    categories = []
    for name in PARENT_CATEGORIES:
        b = category_buckets[name]
        total = b["total_topics"]
        learned = b["stage_counts"]["学習中"] + b["stage_counts"]["復習中"] + b["stage_counts"]["卒業済"]
        b["progress_rate"] = (learned / total) if total else 0.0
        b["accuracy"] = (b["_correct"] / b["_attempts"]) if b["_attempts"] else 0.0
        b["graduation_probability"] = (
            b["_weighted_p_sum"] / b["frequency_weight_sum"] if b["frequency_weight_sum"] else 0.0
        )
        b.pop("_attempts", None)
        b.pop("_correct", None)
        b.pop("_weighted_p_sum", None)
        categories.append(b)

    return {
        "version": 1,
        "generated_at": generated_at.strftime("%Y-%m-%dT%H:%M:%S"),
        "generated_date": generated_at.strftime("%Y-%m-%d"),
        "totals": {
            "topics": len(records),
            "attempted_topics": attempted_topics,
            "graduated_topics": graduated_topics,
            "overall_accuracy": (total_correct / total_attempts) if total_attempts else 0.0,
        },
        "categories": categories,
    }


def render_obsidian_dashboard_md(dashboard_data: dict) -> str:
    totals = dashboard_data.get("totals", {})
    generated_at = dashboard_data.get("generated_at", "")
    lines = [
        "# 学習ダッシュボード",
        "",
        f"- 生成日時: {generated_at}",
        f"- 論点数: {to_int(totals.get('topics', 0))}",
        f"- 学習着手: {to_int(totals.get('attempted_topics', 0))}",
        f"- 卒業済: {to_int(totals.get('graduated_topics', 0))}",
        f"- 全体正答率: {float(totals.get('overall_accuracy', 0.0)) * 100:.1f}%",
        "",
        "| カテゴリ | 論点数 | 未着手 | 学習中 | 復習中 | 卒業済 | 進捗率 | 正答率 | 卒業確率 | フォーカス中 |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]

    for cat in dashboard_data.get("categories", []):
        sc = cat.get("stage_counts", {})
        lines.append(
            "| {name} | {total} | {s0} | {s1} | {s2} | {s3} | {pr:.1f}% | {acc:.1f}% | {gp:.1f}% | {focus} |".format(
                name=cat.get("name", ""),
                total=to_int(cat.get("total_topics", 0)),
                s0=to_int(sc.get("未着手", 0)),
                s1=to_int(sc.get("学習中", 0)),
                s2=to_int(sc.get("復習中", 0)),
                s3=to_int(sc.get("卒業済", 0)),
                pr=float(cat.get("progress_rate", 0.0)) * 100.0,
                acc=float(cat.get("accuracy", 0.0)) * 100.0,
                gp=float(cat.get("graduation_probability", 0.0)) * 100.0,
                focus=to_int(cat.get("focus_active_topics", 0)),
            )
        )

    return "\n".join(lines) + "\n"
