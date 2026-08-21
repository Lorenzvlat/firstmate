#!/usr/bin/env python3
"""Private implementation for Firstmate's bounded telemetry projections.

Public callers are the fixed shell entrypoints documented in docs/worker-telemetry.md.
This module never emits source payloads, exception text, paths, or vendor identities.
"""

from __future__ import annotations

import datetime as dt
import fcntl
import json
import math
import os
import re
import signal
import stat
import sys
import time
from collections import deque
from pathlib import Path
from typing import Any

# Only the modules the Claude status-line path itself uses are imported here.
# That path re-runs on every status-line render of every live Claude worker, so
# the collector, subprocess, and nonce modules are imported inside the few
# functions that need them rather than at every interpreter start.

MAX_SAFE_INTEGER = 9_007_199_254_740_991
TASK_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", re.ASCII)
GENERATION_RE = re.compile(r"^[a-f0-9]{32}$", re.ASCII)
# Claude freshness is activity-based: a worker's own authenticated export or
# status-line render is the only observed activity. Freshness may outlive the
# last such activity by at most this many seconds, never by process lifecycle.
WORKER_LIVENESS_WINDOW = 120.0
COLLECTOR_HEARTBEAT_INTERVAL = 30.0
# Consecutive heartbeat ticks without this collector's own generation-bound
# record before it retires itself.
COLLECTOR_UNBOUND_EXIT_TICKS = 3
# Consecutive heartbeat ticks without the task's own meta file before it retires
# itself. Spawn writes that meta within seconds of starting a collector, so this
# grace only expires for a task whose spawn died before recording it.
COLLECTOR_UNCLAIMED_EXIT_TICKS = 20
PROVIDER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,39}$", re.ASCII)
MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+/-]{0,119}$", re.ASCII)
SCOPE_LABEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+:/-]{0,63}$", re.ASCII)
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$", re.ASCII)
PLAN_ENUM = {
    "free",
    "go",
    "plus",
    "pro",
    "prolite",
    "team",
    "self_serve_business_usage_based",
    "business",
    "enterprise_cbp_usage_based",
    "enterprise",
    "edu",
    "unknown",
}
CLAUDE_PLAN_ENUM = {"free", "pro", "max", "team", "business", "enterprise", "edu", "unknown"}
WARNING_ENUM = {
    "invalid_metadata",
    "invalid_telemetry",
    "worker_limit",
    "output_limit",
    "source_error",
}
MODEL_REASON_LABELS = {
    "explicit_captain_override": "Captain override",
    "matched_dispatch_rule": "Dispatch rule",
    "configured_default": "Configured default",
    "static_default": "Static default",
    "quota_fallback": "Quota fallback",
    "unavailable": "Unavailable",
}
EFFORT_LABELS = {
    "low": "Low",
    "medium": "Medium",
    "high": "High",
    "xhigh": "Extra high",
    "max": "Maximum",
}
REASON_ENUM = {
    "not_authenticated",
    "api_key_not_subscription",
    "timeout",
    "source_error",
    "unsupported_schema",
    "unsupported_machine_readable_source",
    "expired",
    "manual_snapshot",
}
TELEMETRY_KEYS = {
    "schema",
    "taskId",
    "generation",
    "harness",
    "status",
    "observedAt",
    "coverage",
    "final",
    "model",
    "tokens",
}
TOKEN_KEYS = {
    "input",
    "output",
    "cacheRead",
    "cacheWrite",
    "reasoningOutput",
    "total",
    "totalSemantics",
}


def now_epoch() -> float:
    if os.environ.get("FM_TELEMETRY_TEST_MODE") == "1":
        raw = os.environ.get("FM_TELEMETRY_TEST_NOW", "")
        try:
            value = float(raw)
        except ValueError:
            value = 0.0
        if math.isfinite(value) and value >= 0:
            return value
    return time.time()


def iso_from_epoch(value: float) -> str:
    instant = dt.datetime.fromtimestamp(value, tz=dt.timezone.utc)
    return instant.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def parse_iso(value: Any, *, future_slack: int | None = 300) -> float | None:
    if not isinstance(value, str) or not ISO_RE.fullmatch(value):
        return None
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=dt.timezone.utc)
        epoch = parsed.timestamp()
    except (ValueError, OverflowError, OSError):
        return None
    if iso_from_epoch(epoch) != value:
        return None
    if future_slack is not None and epoch > now_epoch() + future_slack:
        return None
    return epoch


def safe_int(value: Any, minimum: int = 0, maximum: int = MAX_SAFE_INTEGER) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if value < minimum or value > maximum:
        return None
    return value


def safe_identifier(value: Any, regex: re.Pattern[str]) -> str | None:
    if isinstance(value, str) and regex.fullmatch(value):
        return value
    return None


def normalized_harness(value: Any) -> str:
    if not isinstance(value, str):
        return "other"
    root = value.split("-", 1)[0].lower()
    return root if root in {"pi", "codex", "claude"} else "other"


def empty_tokens(semantics: str = "source_reported") -> dict[str, Any]:
    return {
        "input": None,
        "output": None,
        "cacheRead": None,
        "cacheWrite": None,
        "reasoningOutput": None,
        "total": None,
        "totalSemantics": semantics,
    }


def unavailable_record(task_id: str, harness: str, generation: str = "") -> dict[str, Any]:
    return {
        "schema": "fm-worker-telemetry.v1",
        "taskId": task_id,
        "generation": generation,
        "harness": normalized_harness(harness),
        "status": "unavailable",
        "observedAt": None,
        "coverage": "none",
        "final": False,
        "model": {"provider": None, "id": None},
        "tokens": empty_tokens(),
    }


def state_root(raw: str) -> Path:
    root = Path(raw)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("unsafe state")
    resolved = root.resolve(strict=True)
    if resolved == Path("/"):
        raise ValueError("unsafe state")
    return resolved


def contained(root: Path, path: Path) -> bool:
    try:
        path.resolve(strict=False).relative_to(root)
        return True
    except (ValueError, OSError):
        return False


def secure_regular(path: Path, root: Path, max_bytes: int, *, owner_only: bool) -> os.stat_result:
    if path.parent.resolve(strict=True) != root or not contained(root, path):
        raise ValueError("outside root")
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise ValueError("unsafe type")
    if info.st_uid != os.geteuid():
        raise ValueError("unsafe owner")
    if owner_only and info.st_mode & 0o077:
        raise ValueError("unsafe mode")
    if info.st_size < 0 or info.st_size > max_bytes:
        raise ValueError("unsafe size")
    if path.resolve(strict=True).parent != root:
        raise ValueError("outside root")
    return info


def read_secure_json(path: Path, root: Path, max_bytes: int, *, owner_only: bool) -> Any:
    before = secure_regular(path, root, max_bytes, owner_only=owner_only)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or (owner_only and opened.st_mode & 0o077)
            or opened.st_size < 0
            or opened.st_size > max_bytes
            or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise ValueError("unsafe opened file")
        data = os.read(fd, max_bytes + 1)
        if len(data) > max_bytes or os.read(fd, 1):
            raise ValueError("too large")
    finally:
        os.close(fd)
    return json.loads(data.decode("utf-8"))


def staging_path(path: Path) -> Path:
    """One hidden owner-only staging name per written file, beside that file.

    Deterministic rather than random, so an interrupted write leaves at most one
    leftover per file and every fixed cleanup list removes it by exact name.
    """
    name = path.name if path.name.startswith(".") else f".{path.name}"
    return path.parent / f"{name}.tmp"


def atomic_bytes(path: Path, data: bytes, max_bytes: int) -> None:
    if len(data) > max_bytes:
        raise ValueError("too large")
    tmp = staging_path(path)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(tmp, flags, 0o600)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
            raise ValueError("unsafe staging")
        os.fchmod(fd, 0o600)
    except BaseException:
        os.close(fd)
        raise
    try:
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def atomic_json(path: Path, root: Path, value: Any, max_bytes: int) -> None:
    if path.parent.resolve(strict=True) != root or not contained(root, path):
        raise ValueError("outside root")
    data = (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    atomic_bytes(path, data, max_bytes)


def atomic_text(path: Path, root: Path, value: str, max_bytes: int) -> None:
    if path.parent.resolve(strict=True) != root or not contained(root, path):
        raise ValueError("outside root")
    atomic_bytes(path, value.encode("utf-8"), max_bytes)


def lock_path(root: Path, task_id: str) -> Path:
    return root / f".{task_id}.telemetry.lock"


def liveness_path(root: Path, task_id: str) -> Path:
    return root / f".{task_id}.claude-live"


def note_worker_liveness(root: Path, task_id: str) -> None:
    """Record observed activity from this task's own Claude worker."""
    if not TASK_ID_RE.fullmatch(task_id):
        return
    path = liveness_path(root, task_id)
    try:
        if path.parent.resolve(strict=True) != root or not contained(root, path):
            return
        flags = os.O_WRONLY | os.O_CREAT
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                return
            os.fchmod(fd, 0o600)
            os.pwrite(fd, b"1", 0)
        finally:
            os.close(fd)
    except OSError:
        return


def worker_liveness_fresh(root: Path, task_id: str) -> bool:
    try:
        info = liveness_path(root, task_id).lstat()
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return False
    if info.st_uid != os.geteuid():
        return False
    return time.time() - info.st_mtime <= WORKER_LIVENESS_WINDOW


class RecordLock:
    def __init__(self, root: Path, task_id: str):
        self.path = lock_path(root, task_id)
        self.fd = -1

    def __enter__(self) -> "RecordLock":
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        self.fd = os.open(self.path, flags, 0o600)
        os.fchmod(self.fd, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        return self

    def __exit__(self, _kind: Any, _value: Any, _trace: Any) -> None:
        fcntl.flock(self.fd, fcntl.LOCK_UN)
        os.close(self.fd)


def validate_tokens(value: Any, *, unavailable: bool = False) -> dict[str, Any] | None:
    if not isinstance(value, dict) or set(value) != TOKEN_KEYS:
        return None
    semantics = value.get("totalSemantics")
    if semantics not in {"source_reported", "sum_of_disjoint_components"}:
        return None
    result: dict[str, Any] = {}
    for key in ("input", "output", "cacheRead", "cacheWrite", "reasoningOutput", "total"):
        item = value.get(key)
        if item is None:
            result[key] = None
        else:
            checked = safe_int(item)
            if checked is None:
                return None
            result[key] = checked
    if unavailable and any(result[key] is not None for key in result):
        return None
    requested = ("input", "output", "cacheRead", "cacheWrite", "total")
    present = [result[key] is not None for key in requested]
    if any(present) and not all(present):
        return None
    result["totalSemantics"] = semantics
    return result


def validate_record(value: Any, task_id: str, harness: str) -> dict[str, Any] | None:
    if not isinstance(value, dict) or set(value) != TELEMETRY_KEYS:
        return None
    if value.get("schema") != "fm-worker-telemetry.v1" or value.get("taskId") != task_id:
        return None
    generation = value.get("generation")
    if not isinstance(generation, str) or not re.fullmatch(r"[a-f0-9]{32}", generation):
        return None
    normalized = normalized_harness(harness)
    if value.get("harness") != normalized:
        return None
    status_value = value.get("status")
    if status_value not in {"fresh", "partial", "unavailable"}:
        return None
    coverage = value.get("coverage")
    if coverage not in {"full_worker", "since_observed", "none"}:
        return None
    final = value.get("final")
    if not isinstance(final, bool):
        return None
    observed = value.get("observedAt")
    if observed is None:
        observed_epoch = None
    else:
        observed_epoch = parse_iso(observed)
        if observed_epoch is None:
            return None
    model = value.get("model")
    if not isinstance(model, dict) or set(model) != {"provider", "id"}:
        return None
    provider = model.get("provider")
    model_id = model.get("id")
    if provider is not None and safe_identifier(provider, PROVIDER_RE) is None:
        return None
    if model_id is not None and safe_identifier(model_id, MODEL_RE) is None:
        return None
    if provider is not None and model_id is None:
        return None
    tokens = validate_tokens(value.get("tokens"), unavailable=status_value == "unavailable")
    if tokens is None:
        return None
    if status_value == "unavailable":
        if coverage != "none" or observed is not None or provider is not None or model_id is not None:
            return None
    elif observed_epoch is None or coverage == "none":
        return None
    if coverage == "full_worker" and status_value == "partial":
        return None
    return {
        "schema": "fm-worker-telemetry.v1",
        "taskId": task_id,
        "generation": generation,
        "harness": normalized,
        "status": status_value,
        "observedAt": observed,
        "coverage": coverage,
        "final": final,
        "model": {"provider": provider, "id": model_id},
        "tokens": tokens,
    }


def meta_projection(path: Path, root: Path) -> dict[str, str] | None:
    try:
        before = secure_regular(path, root, 16 * 1024, owner_only=False)
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
        try:
            opened = os.fstat(fd)
            if (
                not stat.S_ISREG(opened.st_mode)
                or opened.st_uid != os.geteuid()
                or opened.st_size > 16 * 1024
                or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino)
            ):
                return None
            raw = os.read(fd, 16 * 1024 + 1)
        finally:
            os.close(fd)
        if len(raw) > 16 * 1024:
            return None
        lines = raw.decode("utf-8").splitlines()
    except (OSError, UnicodeError, ValueError):
        return None

    def values(key: str) -> list[str]:
        prefix = f"{key}="
        return [line[len(prefix):] for line in lines if line.startswith(prefix)]

    harness_values = values("harness")
    if len(harness_values) != 1 or not harness_values[0] or len(harness_values[0]) > 80:
        return None
    reason_values = values("selection_reason")
    reason = reason_values[0] if len(reason_values) == 1 and reason_values[0] in MODEL_REASON_LABELS else "unavailable"
    effort_values = values("effort")
    effort = effort_values[0] if len(effort_values) == 1 and effort_values[0] in EFFORT_LABELS else "unavailable"
    return {"harness": harness_values[0], "reason": reason, "effort": effort}


class Deadline(Exception):
    """Bounded-budget expiry that no projection handler is allowed to absorb."""


def snapshot_worker(root: Path) -> dict[str, Any]:
    warnings: list[str] = []
    omitted = 0
    candidates: list[tuple[str, Path]] = []
    try:
        entries = list(os.scandir(root))
    except OSError:
        entries = []
        warnings.append("source_error")
    for entry in entries:
        if not entry.name.endswith(".meta"):
            continue
        task_id = entry.name[:-5]
        if not TASK_ID_RE.fullmatch(task_id):
            omitted += 1
            if "invalid_metadata" not in warnings:
                warnings.append("invalid_metadata")
            continue
        candidates.append((task_id, Path(entry.path)))
    candidates.sort(key=lambda item: item[0])
    if len(candidates) > 100:
        omitted += len(candidates) - 100
        candidates = candidates[:100]
        warnings.append("worker_limit")
    workers: list[dict[str, Any]] = []
    for task_id, meta_path in candidates:
        meta = meta_projection(meta_path, root)
        if meta is None:
            omitted += 1
            if "invalid_metadata" not in warnings:
                warnings.append("invalid_metadata")
            continue
        harness = normalized_harness(meta["harness"])
        path = root / f"{task_id}.telemetry.json"
        record: dict[str, Any] | None = None
        if path.exists() or path.is_symlink():
            try:
                candidate = read_secure_json(path, root, 16 * 1024, owner_only=True)
                record = validate_record(candidate, task_id, harness)
            except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
                record = None
            if record is None and "invalid_telemetry" not in warnings:
                warnings.append("invalid_telemetry")
        if record is None:
            record = unavailable_record(task_id, harness)
        status_value = record["status"]
        if status_value != "unavailable" and not record["final"]:
            observed_epoch = parse_iso(record["observedAt"])
            if observed_epoch is None:
                status_value = "unavailable"
            elif now_epoch() - observed_epoch > 90:
                status_value = "stale"
        workers.append(
            {
                "taskId": task_id,
                "harness": harness,
                "status": status_value,
                "observedAt": record["observedAt"],
                "coverage": record["coverage"],
                "model": record["model"],
                "tokens": record["tokens"],
                "selection": {
                    "modelReason": meta["reason"],
                    "modelReasonLabel": MODEL_REASON_LABELS[meta["reason"]],
                    "effort": None if meta["effort"] == "unavailable" else meta["effort"],
                    "effortLabel": EFFORT_LABELS.get(meta["effort"], "Unavailable"),
                },
            }
        )
    warnings = [item for item in warnings if item in WARNING_ENUM][:5]
    result = {
        "schema": "fm-worker-telemetry-snapshot.v1",
        "generatedAt": iso_from_epoch(now_epoch()),
        "workers": workers,
        "omitted": omitted,
        "warnings": warnings,
    }
    encoded = json.dumps(result, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 512 * 1024:
        result["workers"] = []
        result["omitted"] = omitted + len(workers)
        result["warnings"] = ["output_limit"]
    return result


def snapshot_worker_bounded(root: Path) -> dict[str, Any]:
    def timed_out(_signum: int, _frame: Any) -> None:
        raise Deadline

    previous = signal.getsignal(signal.SIGALRM)
    signal.signal(signal.SIGALRM, timed_out)
    signal.setitimer(signal.ITIMER_REAL, 3)
    try:
        return snapshot_worker(root)
    except Deadline:
        return {
            "schema": "fm-worker-telemetry-snapshot.v1",
            "generatedAt": iso_from_epoch(now_epoch()),
            "workers": [],
            "omitted": 0,
            "warnings": ["source_error"],
        }
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def initialize_record(root: Path, task_id: str, harness: str) -> str:
    import secrets

    if not TASK_ID_RE.fullmatch(task_id):
        raise ValueError("bad task")
    generation = secrets.token_hex(16)
    record = unavailable_record(task_id, harness, generation)
    with RecordLock(root, task_id):
        atomic_json(root / f"{task_id}.telemetry.json", root, record, 16 * 1024)
    return generation


def load_current_record(root: Path, task_id: str) -> dict[str, Any]:
    path = root / f"{task_id}.telemetry.json"
    raw = read_secure_json(path, root, 16 * 1024, owner_only=True)
    harness = raw.get("harness") if isinstance(raw, dict) else "other"
    record = validate_record(raw, task_id, harness)
    if record is None:
        raise ValueError("bad telemetry")
    return record


def write_current_record(root: Path, task_id: str, record: dict[str, Any]) -> None:
    validated = validate_record(record, task_id, record.get("harness"))
    if validated is None:
        raise ValueError("bad telemetry")
    atomic_json(root / f"{task_id}.telemetry.json", root, validated, 16 * 1024)


def status_line_model(payload: bytes) -> str | None:
    if len(payload) > 16 * 1024:
        return None
    try:
        source = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(source, dict):
        return None
    model_obj = source.get("model")
    model_id = model_obj.get("id") if isinstance(model_obj, dict) else None
    return safe_identifier(model_id, MODEL_RE)


def claude_status_update(root: Path, task_id: str, generation: str, payload: bytes) -> None:
    if not TASK_ID_RE.fullmatch(task_id) or not GENERATION_RE.fullmatch(generation):
        return
    with RecordLock(root, task_id):
        record = load_current_record(root, task_id)
        if record["generation"] != generation or record["harness"] != "claude":
            return
        note_worker_liveness(root, task_id)
        model_id = status_line_model(payload)
        if model_id is None:
            return
        if record["status"] != "unavailable" and record["model"].get("id") == model_id:
            return
        provider = record["model"].get("provider")
        record["model"] = {"provider": provider, "id": model_id}
        record["observedAt"] = iso_from_epoch(now_epoch())
        if record["status"] == "unavailable":
            record["status"] = "partial"
            record["coverage"] = "since_observed"
        record["final"] = False
        write_current_record(root, task_id, record)


def run_bounded_command(
    argv: list[str],
    env: dict[str, str],
    timeout: float,
    maximum: int,
) -> tuple[int | None, bytes | None, str | None]:
    import selectors
    import subprocess

    try:
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
    except OSError:
        return None, None, "source_error"
    selector = selectors.DefaultSelector()
    assert process.stdout is not None
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + timeout
    reason: str | None = None
    try:
        while time.monotonic() < deadline:
            events = selector.select(max(0, min(0.05, deadline - time.monotonic())))
            if not events:
                if process.poll() is not None:
                    break
                continue
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > maximum:
                reason = "source_error"
                break
        if reason is None and process.poll() is None and time.monotonic() >= deadline:
            reason = "timeout"
    finally:
        selector.close()
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except OSError:
                pass
            try:
                process.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except OSError:
                    pass
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass
    if reason is not None:
        return process.returncode, None, reason
    if len(output) > maximum:
        return process.returncode, None, "source_error"
    return process.returncode, bytes(output), None


def claude_provider() -> str:
    modes = []
    for name, provider in (
        ("CLAUDE_CODE_USE_BEDROCK", "aws-bedrock"),
        ("CLAUDE_CODE_USE_VERTEX", "google-vertex"),
        ("CLAUDE_CODE_USE_FOUNDRY", "azure-foundry"),
    ):
        if os.environ.get(name, "").lower() in {"1", "true", "yes", "on"}:
            modes.append(provider)
    if len(modes) == 1:
        return modes[0]
    if len(modes) > 1:
        return ""
    returncode, output, reason = run_bounded_command(
        ["claude", "auth", "status"], os.environ.copy(), 2, 16 * 1024
    )
    if reason is not None or returncode != 0 or output is None:
        return ""
    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        return ""
    provider = data.get("apiProvider") if isinstance(data, dict) else None
    return {
        "firstParty": "anthropic",
        "bedrock": "aws-bedrock",
        "vertex": "google-vertex",
        "foundry": "azure-foundry",
    }.get(provider, "")


def any_value(value: Any) -> Any:
    if not isinstance(value, dict) or len(value) != 1:
        return None
    if "stringValue" in value and isinstance(value["stringValue"], str):
        return value["stringValue"]
    if "intValue" in value:
        item = value["intValue"]
        if isinstance(item, int) and not isinstance(item, bool):
            return item
        if isinstance(item, str) and re.fullmatch(r"0|[1-9][0-9]*", item):
            try:
                return int(item)
            except ValueError:
                return None
    return None


def otel_attributes(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, list) or len(value) > 64:
        return None
    result: dict[str, Any] = {}
    for item in value:
        if not isinstance(item, dict) or set(item) != {"key", "value"}:
            return None
        key = item.get("key")
        if not isinstance(key, str) or len(key) > 80 or key in result:
            return None
        result[key] = any_value(item.get("value"))
    return result


def iter_log_records(payload: Any) -> list[dict[str, Any]] | None:
    if not isinstance(payload, dict) or set(payload) != {"resourceLogs"}:
        return None
    resources = payload.get("resourceLogs")
    if not isinstance(resources, list) or len(resources) > 8:
        return None
    records: list[dict[str, Any]] = []
    for resource in resources:
        if not isinstance(resource, dict):
            return None
        scopes = resource.get("scopeLogs")
        if not isinstance(scopes, list) or len(scopes) > 16:
            return None
        for scope in scopes:
            if not isinstance(scope, dict):
                return None
            rows = scope.get("logRecords")
            if not isinstance(rows, list) or len(rows) > 128:
                return None
            for row in rows:
                if not isinstance(row, dict):
                    return None
                records.append(row)
                if len(records) > 256:
                    return None
    return records


def project_claude_event(row: dict[str, Any]) -> dict[str, Any] | None:
    attributes = otel_attributes(row.get("attributes"))
    if attributes is None:
        return None
    event_name = attributes.get("event.name") or attributes.get("event_name")
    if event_name != "claude_code.api_request":
        return None
    model = safe_identifier(attributes.get("model"), MODEL_RE)
    query_source = attributes.get("query_source")
    if query_source not in {"main", "subagent", "compaction", "auxiliary", None}:
        query_source = None
    sequence = attributes.get("event.sequence")
    if sequence is None:
        sequence = attributes.get("event_sequence")
    session_id = attributes.get("session.id")
    if session_id is None:
        session_id = attributes.get("session_id")
    if not isinstance(sequence, (str, int)) or isinstance(sequence, bool):
        return None
    if not isinstance(session_id, str) or not session_id or len(session_id) > 200:
        return None
    usage: dict[str, int] = {}
    for source_key, target_key in (
        ("input_tokens", "input"),
        ("output_tokens", "output"),
        ("cache_read_tokens", "cacheRead"),
        ("cache_creation_tokens", "cacheWrite"),
    ):
        checked = safe_int(attributes.get(source_key))
        if checked is None:
            return {"invalid": True, "dedupe": (session_id, str(sequence))}
        usage[target_key] = checked
    return {
        "dedupe": (session_id, str(sequence)),
        "model": model,
        "querySource": query_source,
        "usage": usage,
    }


def claude_privacy_self_test() -> bool:
    marker_values = [
        "PROMPT_PRIVATE_MARKER",
        "ACCOUNT_PRIVATE_MARKER",
        "REQUEST_PRIVATE_MARKER",
        "TOOL_PRIVATE_MARKER",
    ]
    attrs = {
        "event.name": "claude_code.api_request",
        "event.sequence": "8",
        "session.id": "SESSION_PRIVATE_MARKER",
        "model": "claude-sonnet-4-5",
        "query_source": "main",
        "input_tokens": 1,
        "output_tokens": 2,
        "cache_read_tokens": 3,
        "cache_creation_tokens": 4,
        "prompt": marker_values[0],
        "account.uuid": marker_values[1],
        "request.id": marker_values[2],
        "tool.parameters": marker_values[3],
    }
    row = {
        "attributes": [
            {"key": key, "value": {"intValue": str(value)} if isinstance(value, int) else {"stringValue": value}}
            for key, value in attrs.items()
        ]
    }
    projected = project_claude_event(row)
    if not isinstance(projected, dict) or "usage" not in projected:
        return False
    safe_projection = {
        "model": projected.get("model"),
        "querySource": projected.get("querySource"),
        "usage": projected.get("usage"),
    }
    encoded = json.dumps(safe_projection, sort_keys=True)
    return not any(marker in encoded for marker in marker_values + ["SESSION_PRIVATE_MARKER"])


class UsageCoverage:
    """Sticky per-collector record of usage that was admitted but never counted."""

    def __init__(self) -> None:
        import threading

        self.lock = threading.Lock()
        self.dropped = False

    def mark_dropped(self) -> None:
        with self.lock:
            self.dropped = True

    def complete(self) -> bool:
        with self.lock:
            return not self.dropped


def demote_usage_coverage(record: dict[str, Any]) -> None:
    record["status"] = "partial"
    record["coverage"] = "since_observed"
    record["observedAt"] = iso_from_epoch(now_epoch())
    record["final"] = False


def note_usage_gap(root: Path, task_id: str, generation: str, coverage: UsageCoverage) -> None:
    coverage.mark_dropped()
    try:
        with RecordLock(root, task_id):
            record = load_current_record(root, task_id)
            if record["generation"] != generation or record["harness"] != "claude":
                return
            demote_usage_coverage(record)
            write_current_record(root, task_id, record)
    except (OSError, ValueError, json.JSONDecodeError):
        return


def update_claude_usage(
    root: Path,
    task_id: str,
    generation: str,
    provider: str | None,
    projected: dict[str, Any],
    coverage: UsageCoverage,
) -> None:
    with RecordLock(root, task_id):
        record = load_current_record(root, task_id)
        if record["generation"] != generation or record["harness"] != "claude":
            return
        usage = projected.get("usage")
        if projected.get("invalid") or not isinstance(usage, dict):
            coverage.mark_dropped()
            demote_usage_coverage(record)
            write_current_record(root, task_id, record)
            return
        current = record["tokens"]
        if any(current[key] is None for key in ("input", "output", "cacheRead", "cacheWrite", "total")):
            current = {
                "input": 0,
                "output": 0,
                "cacheRead": 0,
                "cacheWrite": 0,
                "reasoningOutput": None,
                "total": 0,
                "totalSemantics": "sum_of_disjoint_components",
            }
        next_values: dict[str, int] = {}
        for key in ("input", "output", "cacheRead", "cacheWrite"):
            total = current[key] + usage[key]
            if total > MAX_SAFE_INTEGER:
                coverage.mark_dropped()
                demote_usage_coverage(record)
                write_current_record(root, task_id, record)
                return
            next_values[key] = total
        total = sum(next_values.values())
        if total > MAX_SAFE_INTEGER:
            coverage.mark_dropped()
            demote_usage_coverage(record)
            write_current_record(root, task_id, record)
            return
        record["tokens"] = {
            **next_values,
            "reasoningOutput": None,
            "total": total,
            "totalSemantics": "sum_of_disjoint_components",
        }
        if projected.get("querySource") == "main" and projected.get("model") is not None:
            record["model"] = {"provider": provider, "id": projected["model"]}
        if coverage.complete():
            record["status"] = "fresh"
            record["coverage"] = "full_worker"
        else:
            record["status"] = "partial"
            record["coverage"] = "since_observed"
        record["observedAt"] = iso_from_epoch(now_epoch())
        record["final"] = False
        write_current_record(root, task_id, record)


def heartbeat_tick(root: Path, task_id: str, generation: str) -> bool:
    """Heartbeat only while the task's own worker keeps producing observed activity."""
    if not worker_liveness_fresh(root, task_id):
        return False
    heartbeat_record(root, task_id, generation)
    return True


def collector_heartbeat_interval() -> float:
    """Heartbeat cadence, shortened only under this module's own test mode."""
    if os.environ.get("FM_TELEMETRY_TEST_MODE") == "1":
        try:
            value = float(os.environ.get("FM_TELEMETRY_TEST_HEARTBEAT", ""))
        except ValueError:
            return COLLECTOR_HEARTBEAT_INTERVAL
        if math.isfinite(value) and 0.01 <= value <= COLLECTOR_HEARTBEAT_INTERVAL:
            return value
    return COLLECTOR_HEARTBEAT_INTERVAL


def record_still_bound(root: Path, task_id: str, generation: str) -> bool:
    """Is this collector's own generation-bound record still present?

    The record is written before the collector starts and removed only by task
    cleanup, so a missing or re-generated record means this collector has nothing
    left to write for. Read without the record lock so a bound check never
    recreates a lock file that cleanup already removed. An unreadable but present
    record counts as bound, because a transient read failure is not cleanup.
    """
    path = root / f"{task_id}.telemetry.json"
    try:
        raw = read_secure_json(path, root, 16 * 1024, owner_only=True)
    except FileNotFoundError:
        return False
    except (OSError, ValueError, json.JSONDecodeError):
        return os.path.lexists(path)
    return isinstance(raw, dict) and raw.get("generation") == generation


def task_claimed(root: Path, task_id: str) -> bool:
    """Has the spawn that started this collector recorded the task yet?"""
    return os.path.lexists(root / f"{task_id}.meta")


def drop_own_control_record(root: Path, task_id: str) -> None:
    """Retire the control record a self-exiting collector wrote for itself.

    Only when it still names this process, so a collector that a restart already
    replaced never removes its successor's record.
    """
    path = root / f"{task_id}.claude-telemetry.json"
    try:
        control = read_secure_json(path, root, 4096, owner_only=True)
        if isinstance(control, dict) and control.get("pid") == os.getpid():
            path.unlink()
    except (OSError, ValueError, json.JSONDecodeError):
        return


def heartbeat_record(root: Path, task_id: str, generation: str) -> None:
    try:
        with RecordLock(root, task_id):
            record = load_current_record(root, task_id)
            if record["generation"] != generation or record["harness"] != "claude":
                return
            if record["status"] != "unavailable":
                record["observedAt"] = iso_from_epoch(now_epoch())
                write_current_record(root, task_id, record)
    except (OSError, ValueError, json.JSONDecodeError):
        return


def build_claude_collector(
    root: Path,
    task_id: str,
    generation: str,
    provider: str | None,
    token: str,
) -> Any:
    """Build this task's loopback collector.

    The collector classes are defined here so the HTTP server, threading, and
    hashing modules load in the collector process only, never on the status-line
    path that renders while a Claude worker runs.
    """
    import hashlib
    import http.server
    import threading

    class ClaudeCollector(http.server.ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = False

        def __init__(self) -> None:
            super().__init__(("127.0.0.1", 0), ClaudeCollectorHandler)
            if self.server_address[0] not in {"127.0.0.1", "::1"}:
                raise ValueError("non-loopback")
            self.root = root
            self.task_id = task_id
            self.generation = generation
            self.provider = provider
            self.token = token
            self.usage_coverage = UsageCoverage()
            self.seen: set[str] = set()
            self.order: deque[str] = deque()
            self.seen_lock = threading.Lock()

        def admit(self, projected: dict[str, Any]) -> bool:
            pair = projected.get("dedupe")
            if not isinstance(pair, tuple) or len(pair) != 2:
                return False
            digest = hashlib.sha256((self.token + "\0" + pair[0] + "\0" + pair[1]).encode("utf-8")).hexdigest()
            with self.seen_lock:
                if digest in self.seen:
                    return False
                self.seen.add(digest)
                self.order.append(digest)
                while len(self.order) > 4096:
                    retired = self.order.popleft()
                    self.seen.discard(retired)
            return True

    class ClaudeCollectorHandler(http.server.BaseHTTPRequestHandler):
        server: "ClaudeCollector"
        protocol_version = "HTTP/1.1"

        def log_message(self, _format: str, *_args: Any) -> None:
            return

        def generic(self, code: int) -> None:
            body = b'{"status":"rejected"}\n'
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self.generic(404)

        def do_HEAD(self) -> None:
            self.generic(404)

        def do_POST(self) -> None:
            if self.path != "/v1/logs":
                self.generic(404)
                return
            if self.headers.get("x-firstmate-telemetry-token") != self.server.token:
                self.generic(403)
                return
            note_worker_liveness(self.server.root, self.server.task_id)
            content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            if content_type != "application/json":
                self.generic(415)
                return
            try:
                length = int(self.headers.get("Content-Length", ""))
            except ValueError:
                self.generic(400)
                return
            if length < 0 or length > 64 * 1024:
                self.generic(413)
                return
            self.connection.settimeout(2)
            payload_bytes = self.rfile.read(length)
            if len(payload_bytes) != length:
                self.generic(400)
                return
            try:
                payload = json.loads(payload_bytes.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError):
                self.generic(400)
                return
            records = iter_log_records(payload)
            if records is None:
                note_usage_gap(
                    self.server.root,
                    self.server.task_id,
                    self.server.generation,
                    self.server.usage_coverage,
                )
                self.generic(400)
                return
            for row in records:
                projected = project_claude_event(row)
                if projected is None or not self.server.admit(projected):
                    continue
                try:
                    update_claude_usage(
                        self.server.root,
                        self.server.task_id,
                        self.server.generation,
                        self.server.provider,
                        projected,
                        self.server.usage_coverage,
                    )
                except (OSError, ValueError, json.JSONDecodeError):
                    note_usage_gap(
                        self.server.root,
                        self.server.task_id,
                        self.server.generation,
                        self.server.usage_coverage,
                    )
                    continue
            body = b"{}\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

    return ClaudeCollector()


def collector_process(root: Path, task_id: str, bootstrap: Path, ready: Path) -> int:
    import threading

    try:
        config = read_secure_json(bootstrap, root, 4096, owner_only=True)
        bootstrap.unlink()
        if not isinstance(config, dict) or set(config) != {"generation", "provider", "token"}:
            return 1
        generation = config.get("generation")
        token = config.get("token")
        provider = config.get("provider")
        if not isinstance(generation, str) or not re.fullmatch(r"[a-f0-9]{32}", generation):
            return 1
        if not isinstance(token, str) or not re.fullmatch(r"[a-f0-9]{64}", token):
            return 1
        if provider == "":
            provider = None
        if provider is not None and safe_identifier(provider, PROVIDER_RE) is None:
            return 1
        server = build_claude_collector(root, task_id, generation, provider, token)
        process_start = process_start_identity(os.getpid())
        if process_start is None:
            return 1
        control = {
            "schema": "fm-claude-telemetry-collector.v1",
            "taskId": task_id,
            "pid": os.getpid(),
            "processStart": process_start,
        }
        atomic_json(root / f"{task_id}.claude-telemetry.json", root, control, 4096)
        atomic_json(
            ready,
            root,
            {"port": server.server_address[1], "token": token},
            4096,
        )
    except (OSError, ValueError, json.JSONDecodeError):
        return 1

    stopping = threading.Event()
    retired_self = threading.Event()

    def stop(_signum: int, _frame: Any) -> None:
        stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def heartbeat() -> None:
        # A collector also retires itself, so a task whose cleanup never ran - a
        # spawn killed before it recorded the task, or a removed state directory
        # - cannot leave a loopback listener behind for the rest of the session.
        # Both bounds track task-cleanup artifacts rather than worker lifecycle,
        # so an alive-but-idle worker keeps its collector.
        unbound = 0
        unclaimed = 0
        interval = collector_heartbeat_interval()
        while not stopping.wait(interval):
            unbound = 0 if record_still_bound(root, task_id, generation) else unbound + 1
            unclaimed = 0 if task_claimed(root, task_id) else unclaimed + 1
            if unbound >= COLLECTOR_UNBOUND_EXIT_TICKS or unclaimed >= COLLECTOR_UNCLAIMED_EXIT_TICKS:
                retired_self.set()
                stop(signal.SIGTERM, None)
                return
            if unbound == 0:
                heartbeat_tick(root, task_id, generation)

    threading.Thread(target=heartbeat, daemon=True).start()
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        if retired_self.is_set():
            drop_own_control_record(root, task_id)
    return 0


def bounded_ps(pid: int, field: str, maximum: int) -> str | None:
    import subprocess

    try:
        completed = subprocess.run(
            ["ps", "-ww", "-p", str(pid), "-o", f"{field}="],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=1,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0 or not completed.stdout or len(completed.stdout) > maximum:
        return None
    return completed.stdout.decode("utf-8", "replace").strip()


def process_start_identity(pid: int) -> str | None:
    value = bounded_ps(pid, "lstart", 128)
    if value is None or not re.fullmatch(r"[A-Za-z]{3} [A-Za-z]{3} [ 0-9][0-9] [0-9:]{8} [0-9]{4}", value):
        return None
    return value


def collector_identity_matches(
    pid: int,
    expected_start: str,
    root: Path,
    task_id: str,
) -> bool:
    if process_start_identity(pid) != expected_start:
        return False
    command = bounded_ps(pid, "command", 16 * 1024)
    if command is None:
        return False
    script = str(Path(__file__).resolve())
    bootstrap = str(root / f".{task_id}.claude-bootstrap.json")
    ready = str(root / f".{task_id}.claude-ready.json")
    expected = " ".join([script, "claude-collector", str(root), task_id, bootstrap, ready])
    # ps joins argv with plain spaces and never quotes, so the raw tail is
    # compared as-is: reconstructing argv would mis-split a state root, task tmp
    # path, or interpreter path that contains whitespace and would then silently
    # refuse to retire this task's own collector.
    suffix = f" {expected}"
    return command.endswith(suffix) and len(command) > len(suffix)


def stop_collector(root: Path, task_id: str, *, remove_record: bool) -> None:
    control_path = root / f"{task_id}.claude-telemetry.json"
    try:
        control = read_secure_json(control_path, root, 4096, owner_only=True)
    except (OSError, ValueError, json.JSONDecodeError):
        control = None
    if isinstance(control, dict) and set(control) == {"schema", "taskId", "pid", "processStart"}:
        pid = safe_int(control.get("pid"), 2, 2_147_483_647)
        process_start = control.get("processStart")
        if (
            control.get("schema") == "fm-claude-telemetry-collector.v1"
            and control.get("taskId") == task_id
            and pid is not None
            and isinstance(process_start, str)
            and collector_identity_matches(pid, process_start, root, task_id)
        ):
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            else:
                deadline = time.monotonic() + 1.5
                while time.monotonic() < deadline:
                    if not collector_identity_matches(pid, process_start, root, task_id):
                        break
                    time.sleep(0.05)
                else:
                    # TERM escalation remains bound to the same task, process
                    # start instant, script, state root, and exact argv.
                    if collector_identity_matches(pid, process_start, root, task_id):
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except (ProcessLookupError, PermissionError):
                            pass
                        kill_deadline = time.monotonic() + 0.5
                        while time.monotonic() < kill_deadline:
                            if not collector_identity_matches(pid, process_start, root, task_id):
                                break
                            time.sleep(0.05)
    # Each write stages at one deterministic name beside its file, so cleanup
    # removes an interrupted write's leftover by exact name too.
    for path in (
        control_path,
        root / f".{task_id}.claude-telemetry.json.tmp",
        root / f".{task_id}.claude-ready.json",
        root / f".{task_id}.claude-ready.json.tmp",
        root / f".{task_id}.claude-bootstrap.json",
        root / f".{task_id}.claude-bootstrap.json.tmp",
        liveness_path(root, task_id),
    ):
        try:
            path.unlink()
        except FileNotFoundError:
            pass
    if remove_record:
        for path in (
            root / f"{task_id}.telemetry.json",
            root / f".{task_id}.telemetry.json.tmp",
            lock_path(root, task_id),
        ):
            try:
                path.unlink()
            except FileNotFoundError:
                pass


def shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def start_collector(root: Path, task_id: str, env_path: Path) -> bool:
    import secrets
    import subprocess

    if not claude_privacy_self_test() or not TASK_ID_RE.fullmatch(task_id):
        return False
    with RecordLock(root, task_id):
        record = load_current_record(root, task_id)
    if record["harness"] != "claude":
        return False
    stop_collector(root, task_id, remove_record=False)
    provider = claude_provider()
    token = secrets.token_hex(32)
    bootstrap = root / f".{task_id}.claude-bootstrap.json"
    ready = root / f".{task_id}.claude-ready.json"
    atomic_json(
        bootstrap,
        root,
        {"generation": record["generation"], "provider": provider, "token": token},
        4096,
    )
    try:
        child = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "claude-collector",
                str(root),
                task_id,
                str(bootstrap),
                str(ready),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
            start_new_session=True,
        )
    except OSError:
        try:
            bootstrap.unlink()
        except FileNotFoundError:
            pass
        return False

    def abandon() -> bool:
        # A failed start never leaves the task's own collector running.
        try:
            child.terminate()
        except OSError:
            pass
        try:
            child.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            pass
        stop_collector(root, task_id, remove_record=False)
        return False

    deadline = time.monotonic() + 2
    ready_value: Any = None
    while time.monotonic() < deadline:
        if child.poll() is not None:
            break
        try:
            ready_value = read_secure_json(ready, root, 4096, owner_only=True)
            break
        except (FileNotFoundError, OSError, ValueError, json.JSONDecodeError):
            time.sleep(0.02)
    try:
        ready.unlink()
    except FileNotFoundError:
        pass
    if not isinstance(ready_value, dict) or set(ready_value) != {"port", "token"}:
        return abandon()
    port = safe_int(ready_value.get("port"), 1, 65535)
    ready_token = ready_value.get("token")
    if port is None or ready_token != token:
        return abandon()
    endpoint = f"http://127.0.0.1:{port}"
    exports = {
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        "OTEL_METRICS_EXPORTER": "none",
        "OTEL_LOGS_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
        "OTEL_EXPORTER_OTLP_HEADERS": f"x-firstmate-telemetry-token={token}",
        "OTEL_LOG_USER_PROMPTS": "0",
        "OTEL_LOG_ASSISTANT_RESPONSES": "0",
        "OTEL_LOG_TOOL_DETAILS": "0",
        "OTEL_LOG_RAW_API_BODIES": "0",
        "OTEL_METRICS_INCLUDE_SESSION_ID": "false",
        "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "false",
    }
    text = "".join(f"export {key}={shell_single_quote(value)}\n" for key, value in exports.items())
    try:
        env_root = env_path.parent.resolve(strict=True)
        if env_path.parent.is_symlink() or not contained(env_root, env_path):
            return abandon()
        atomic_text(env_path, env_root, text, 8192)
    except (OSError, ValueError):
        return abandon()
    return True


def codex_version_reason(env: dict[str, str], deadline: float) -> str | None:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        return "timeout"
    returncode, output, reason = run_bounded_command(
        ["codex", "--version"], env, min(1, remaining), 256
    )
    if reason is not None:
        return reason
    if returncode != 0 or output is None:
        return "source_error"
    if re.fullmatch(rb"codex-cli 0\.144\.([0-9]{1,3})\s*", output) is None:
        return "unsupported_schema"
    return None


def rpc_codex_plan() -> tuple[dict[str, Any] | None, str | None]:
    import selectors
    import subprocess

    deadline = time.monotonic() + 5
    env = {key: os.environ[key] for key in ("HOME", "PATH", "LANG") if key in os.environ}
    if "CODEX_HOME" in os.environ:
        env["CODEX_HOME"] = os.environ["CODEX_HOME"]
    version_reason = codex_version_reason(env, deadline)
    if version_reason is not None:
        return None, version_reason
    command = ["codex", "-s", "read-only", "-a", "untrusted", "app-server", "--stdio"]
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
    except OSError:
        return None, "source_error"
    requests = [
        {"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "firstmate", "version": "1.0.0"}}},
        {"id": 2, "method": "account/read", "params": {"refreshToken": False}},
        {"id": 3, "method": "account/rateLimits/read", "params": None},
    ]
    try:
        assert process.stdin is not None
        for request in requests:
            process.stdin.write(json.dumps(request, separators=(",", ":")).encode("utf-8") + b"\n")
        process.stdin.flush()
    except (OSError, BrokenPipeError):
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            pass
        return None, "source_error"
    responses: dict[int, Any] = {}
    selector = selectors.DefaultSelector()
    assert process.stdout is not None
    selector.register(process.stdout, selectors.EVENT_READ)
    buffer = b""
    total = 0
    reason: str | None = None
    try:
        while time.monotonic() < deadline and not {1, 2, 3}.issubset(responses):
            events = selector.select(max(0, min(0.1, deadline - time.monotonic())))
            if not events:
                if process.poll() is not None:
                    break
                continue
            chunk = os.read(process.stdout.fileno(), 4096)
            if not chunk:
                break
            total += len(chunk)
            if total > 64 * 1024:
                reason = "unsupported_schema"
                break
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if len(line) > 32 * 1024:
                    reason = "unsupported_schema"
                    break
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    reason = "unsupported_schema"
                    break
                if not isinstance(message, dict):
                    continue
                response_id = message.get("id")
                if response_id in {1, 2, 3}:
                    if "error" in message or "result" not in message:
                        reason = "source_error"
                        break
                    responses[response_id] = message["result"]
            if reason is not None:
                break
        if reason is None and not {1, 2, 3}.issubset(responses):
            reason = "timeout" if time.monotonic() >= deadline else "source_error"
    finally:
        selector.close()
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            pass
        try:
            process.wait(timeout=0.5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
    if reason is not None:
        return None, reason
    account = responses[2]
    limits = responses[3]
    if not isinstance(account, dict) or set(account) != {"account", "requiresOpenaiAuth"}:
        return None, "unsupported_schema"
    account_value = account.get("account")
    if account_value is None:
        return None, "not_authenticated"
    if not isinstance(account_value, dict):
        return None, "unsupported_schema"
    account_type = account_value.get("type")
    if account_type == "apiKey":
        return None, "api_key_not_subscription"
    if account_type != "chatgpt":
        return None, "not_authenticated"
    plan = account_value.get("planType")
    if plan not in PLAN_ENUM:
        return None, "unsupported_schema"
    if not isinstance(limits, dict):
        return None, "unsupported_schema"
    allowed_top = {"rateLimits", "rateLimitsByLimitId", "rateLimitResetCredits"}
    if "rateLimits" not in limits or not set(limits).issubset(allowed_top):
        return None, "unsupported_schema"
    return {"plan": plan, "limits": limits}, None


def window_label(minutes: int | None) -> str:
    if minutes == 300:
        return "5-hour"
    if minutes == 10080:
        return "7-day"
    if minutes is None:
        return "Unknown duration"
    if minutes % 1440 == 0:
        return f"{minutes // 1440}-day"
    if minutes % 60 == 0:
        return f"{minutes // 60}-hour"
    return f"{minutes}-minute"


def safe_scope_label(value: Any) -> str | None:
    if not isinstance(value, str) or not SCOPE_LABEL_RE.fullmatch(value):
        return None
    lowered = value.lower()
    if any(marker in lowered for marker in ("account", "limit_id", "uuid", "@", "http", "token", "secret")):
        return None
    # The current closed authorization recognizes model-family labels only.
    # Unknown product prose and opaque limit names receive the fixed fallback.
    if re.fullmatch(r"(?:gpt|codex|chatgpt|o[1-9])[a-z0-9 ._+:/-]*", lowered) is None:
        return None
    return value


def classify_scope(label: str | None) -> str:
    if label is None:
        return "unknown"
    lowered = label.lower()
    if re.search(r"(?:^|[-_. ])(?:gpt|codex|o[1-9])(?:$|[-_. 0-9])", lowered):
        return "model"
    return "feature"


def project_window(window: Any, scope: str, slot: str, label: str, ordinal: int) -> dict[str, Any] | None:
    if not isinstance(window, dict) or not {"usedPercent"}.issubset(window):
        return None
    if not set(window).issubset({"usedPercent", "windowDurationMins", "resetsAt"}):
        return None
    used = safe_int(window.get("usedPercent"), 0, 100)
    if used is None:
        return None
    minutes_value = window.get("windowDurationMins")
    if minutes_value is None:
        minutes = None
        seconds = None
        duration_key = "unknown"
    else:
        minutes = safe_int(minutes_value, 1, MAX_SAFE_INTEGER // 60)
        if minutes is None:
            return None
        seconds = minutes * 60
        duration_key = str(minutes)
    reset_value = window.get("resetsAt")
    if reset_value is None:
        reset = None
    else:
        reset_epoch = safe_int(reset_value, 0, 253_402_300_799)
        if reset_epoch is None:
            return None
        try:
            reset = iso_from_epoch(reset_epoch)
        except (ValueError, OverflowError, OSError):
            return None
    suffix = "" if scope == "general" else f":{ordinal}"
    return {
        "key": f"{scope}:{slot}:{duration_key}{suffix}",
        "scope": scope,
        "label": window_label(minutes) if scope == "general" else label,
        "usedPercent": used,
        "remainingPercent": 100 - used,
        "windowSeconds": seconds,
        "resetsAt": reset,
    }


def project_plan(source: dict[str, Any]) -> dict[str, Any] | None:
    plan = source.get("plan")
    limits = source.get("limits")
    if plan not in PLAN_ENUM or not isinstance(limits, dict):
        return None
    general = limits.get("rateLimits")
    if not isinstance(general, dict):
        return None
    windows: list[dict[str, Any]] = []
    for slot in ("primary", "secondary"):
        value = general.get(slot)
        if value is None:
            continue
        projected = project_window(value, "general", slot, "General", 0)
        if projected is None:
            return None
        windows.append(projected)
    extra = limits.get("rateLimitsByLimitId")
    if extra is not None:
        if not isinstance(extra, dict) or len(extra) > 64:
            return None
        candidates: list[tuple[str, dict[str, Any]]] = []
        general_shape = {key: general.get(key) for key in ("primary", "secondary")}
        for snapshot in extra.values():
            if not isinstance(snapshot, dict):
                return None
            snapshot_shape = {key: snapshot.get(key) for key in ("primary", "secondary")}
            # The installed protocol mirrors the historical general bucket in
            # rateLimitsByLimitId. Do not duplicate that compatibility row.
            if snapshot_shape == general_shape:
                continue
            label_value = safe_scope_label(snapshot.get("limitName"))
            label = label_value or "Scoped limit"
            candidates.append((label, snapshot))
        candidates.sort(key=lambda item: (item[0], json.dumps(item[1], sort_keys=True)))
        for ordinal, (label, snapshot) in enumerate(candidates, start=1):
            scope = classify_scope(label if label != "Scoped limit" else None)
            for slot in ("primary", "secondary"):
                value = snapshot.get(slot)
                if value is None:
                    continue
                projected = project_window(value, scope, slot, label, ordinal)
                if projected is None:
                    return None
                windows.append(projected)
                if len(windows) >= 12:
                    break
            if len(windows) >= 12:
                break
    if len(windows) > 12:
        windows = windows[:12]
    observed = iso_from_epoch(now_epoch())
    return {
        "provider": "codex",
        "product": "chatgpt_subscription",
        "plan": plan,
        "status": "fresh",
        "observedAt": observed,
        "expiresAt": None,
        "reason": None,
        "windows": windows,
    }


def claude_plan() -> dict[str, Any]:
    return {
        "provider": "claude",
        "product": "claude_subscription",
        "plan": None,
        "status": "unavailable",
        "observedAt": None,
        "expiresAt": None,
        "reason": "unsupported_machine_readable_source",
        "windows": [],
    }


def valid_plan_provider(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    expected = {"provider", "product", "plan", "status", "observedAt", "expiresAt", "reason", "windows"}
    if set(value) != expected:
        return None
    if value.get("provider") != "codex" or value.get("product") != "chatgpt_subscription":
        return None
    if value.get("plan") not in PLAN_ENUM:
        return None
    if value.get("status") not in {"fresh", "stale"}:
        return None
    observed = parse_iso(value.get("observedAt"))
    if observed is None or value.get("expiresAt") is not None:
        return None
    reason = value.get("reason")
    if reason is not None and reason not in REASON_ENUM:
        return None
    windows = value.get("windows")
    if not isinstance(windows, list) or len(windows) > 12:
        return None
    for window in windows:
        if not isinstance(window, dict) or set(window) != {
            "key", "scope", "label", "usedPercent", "remainingPercent", "windowSeconds", "resetsAt"
        }:
            return None
        if not isinstance(window["key"], str) or len(window["key"]) > 100:
            return None
        if window["scope"] not in {"general", "model", "feature", "unknown"}:
            return None
        if not isinstance(window["label"], str) or not window["label"] or len(window["label"]) > 64:
            return None
        used = safe_int(window["usedPercent"], 0, 100)
        remaining = safe_int(window["remainingPercent"], 0, 100)
        if used is None or remaining != 100 - used:
            return None
        if window["windowSeconds"] is not None and safe_int(window["windowSeconds"], 60) is None:
            return None
        if window["resetsAt"] is not None and parse_iso(window["resetsAt"], future_slack=None) is None:
            return None
    return value


def cached_plan(root: Path) -> dict[str, Any] | None:
    path = root / ".plan-usage-cache.json"
    try:
        raw = read_secure_json(path, root, 64 * 1024, owner_only=True)
    except (OSError, ValueError, json.JSONDecodeError, UnicodeError):
        return None
    return valid_plan_provider(raw)


def windows_unexpired(record: dict[str, Any]) -> bool:
    for window in record.get("windows", []):
        reset = window.get("resetsAt")
        if reset is not None:
            reset_epoch = parse_iso(reset, future_slack=None)
            if reset_epoch is None or now_epoch() >= reset_epoch:
                return False
    return True


def cache_usable(record: dict[str, Any], max_age: int) -> bool:
    observed = parse_iso(record.get("observedAt"))
    if observed is None or now_epoch() - observed > max_age:
        return False
    return windows_unexpired(record)


def unavailable_codex(reason: str) -> dict[str, Any]:
    if reason not in REASON_ENUM:
        reason = "source_error"
    return {
        "provider": "codex",
        "product": "chatgpt_subscription",
        "plan": None,
        "status": "unavailable",
        "observedAt": None,
        "expiresAt": None,
        "reason": reason,
        "windows": [],
    }


def project_manual_claude(raw: Any) -> dict[str, Any]:
    """Validate and project the single fm-plan-usage-manual.v1 contract."""
    expected = {"schema", "provider", "plan", "observedAt", "expiresAt", "windows"}
    if not isinstance(raw, dict) or set(raw) != expected:
        record = claude_plan()
        record["reason"] = "source_error"
        return record
    if raw.get("schema") != "fm-plan-usage-manual.v1" or raw.get("provider") != "claude":
        record = claude_plan()
        record["reason"] = "source_error"
        return record
    plan = raw.get("plan")
    observed_at = raw.get("observedAt")
    expires_at = raw.get("expiresAt")
    observed_epoch = parse_iso(observed_at)
    expires_epoch = parse_iso(expires_at, future_slack=None)
    if (
        plan not in CLAUDE_PLAN_ENUM
        or observed_epoch is None
        or expires_epoch is None
        or expires_epoch <= observed_epoch
    ):
        record = claude_plan()
        record["reason"] = "source_error"
        return record
    if now_epoch() >= expires_epoch:
        record = claude_plan()
        record["reason"] = "expired"
        return record
    source_windows = raw.get("windows")
    if not isinstance(source_windows, list) or not 1 <= len(source_windows) <= 12:
        record = claude_plan()
        record["reason"] = "source_error"
        return record
    windows: list[dict[str, Any]] = []
    seen_keys: set[str] = set()
    for source_window in source_windows:
        if not isinstance(source_window, dict) or set(source_window) != {
            "slot", "usedPercent", "windowDurationMins", "resetsAt"
        }:
            record = claude_plan()
            record["reason"] = "source_error"
            return record
        slot = source_window.get("slot")
        if slot not in {"primary", "secondary"}:
            record = claude_plan()
            record["reason"] = "source_error"
            return record
        numeric_window = {key: source_window[key] for key in ("usedPercent", "windowDurationMins", "resetsAt")}
        projected = project_window(numeric_window, "general", slot, "General", 0)
        if projected is None or projected["key"] in seen_keys:
            record = claude_plan()
            record["reason"] = "source_error"
            return record
        seen_keys.add(projected["key"])
        windows.append(projected)
    result = {
        "provider": "claude",
        "product": "claude_subscription",
        "plan": plan,
        "status": "manual",
        "observedAt": observed_at,
        "expiresAt": expires_at,
        "reason": "manual_snapshot",
        "windows": windows,
    }
    if not windows_unexpired(result):
        record = claude_plan()
        record["reason"] = "expired"
        return record
    return result


def manual_claude_plan(config: Path, enabled: bool) -> dict[str, Any]:
    if not enabled:
        return claude_plan()
    try:
        root = state_root(str(config))
        raw = read_secure_json(root / "plan-usage-manual.json", root, 16 * 1024, owner_only=True)
    except (OSError, ValueError, json.JSONDecodeError, UnicodeError):
        record = claude_plan()
        record["reason"] = "source_error"
        return record
    return project_manual_claude(raw)


PROMPT_RETRIES = 3


def prompt_line(label: str, max_length: int = 64) -> str:
    sys.stderr.write(label)
    sys.stderr.flush()
    value = sys.stdin.readline(max_length + 2)
    if not value or not value.endswith("\n") or len(value.rstrip("\n")) > max_length:
        raise ValueError("invalid input")
    return value.rstrip("\n")


def prompt_value(label: str, parser: Any) -> Any:
    for attempt in range(PROMPT_RETRIES + 1):
        try:
            parsed = parser(prompt_line(label))
        except ValueError:
            parsed = None
        if parsed is not None:
            return parsed
        if attempt < PROMPT_RETRIES:
            print("Invalid value; try again.", file=sys.stderr)
    raise ValueError("invalid input")


def prompt_enum(label: str, allowed: set[str]) -> str:
    return prompt_value(label, lambda value: value if value in allowed else None)


def prompt_integer(label: str, minimum: int, maximum: int) -> int:
    def parse(value: str) -> int | None:
        if not re.fullmatch(r"0|[1-9][0-9]*", value, re.ASCII):
            return None
        parsed = int(value)
        return parsed if minimum <= parsed <= maximum else None

    return prompt_value(label, parse)


def prompt_iso(
    label: str,
    *,
    future_slack: int | None = 300,
    after: float | None = None,
    require_future: bool = False,
    whole_second: bool = False,
) -> str:
    def parse(value: str) -> str | None:
        epoch = parse_iso(value, future_slack=future_slack)
        if epoch is None or (after is not None and epoch <= after):
            return None
        if require_future and epoch <= now_epoch():
            return None
        if whole_second and not epoch.is_integer():
            return None
        return value

    return prompt_value(label, parse)


def manual_private_dir(root: Path) -> Path:
    import secrets
    for _ in range(128):
        path = root / f".plan-usage-manual.{secrets.token_hex(16)}"
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            continue
        info = path.lstat()
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
            or path.parent.resolve(strict=True) != root
        ):
            raise ValueError("unsafe transaction directory")
        return path
    raise ValueError("could not create transaction directory")


def rename_noreplace(source: Path, target: Path) -> None:
    import ctypes
    import errno
    library = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    target_bytes = os.fsencode(target)
    if sys.platform == "darwin":
        result = library.renamex_np(source_bytes, target_bytes, 0x00000004)
    elif hasattr(library, "renameat2"):
        result = library.renameat2(-2, source_bytes, -2, target_bytes, 1)
    else:
        raise OSError(errno.ENOTSUP, "exclusive rename unavailable")
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), target)


def restore_manual_entry(captured: Path, target: Path) -> None:
    rename_noreplace(captured, target)


def manual_plan_import(config: Path) -> None:
    root = state_root(str(config))
    target = root / "plan-usage-manual.json"
    observed = None
    if target.exists() or target.is_symlink():
        observed = secure_regular(target, root, 16 * 1024, owner_only=True)
    print("Enter values transcribed from Claude's interactive usage screen. Text, pasted UI output, and JSON are not accepted.", file=sys.stderr)
    plan = prompt_enum(
        "Claude plan (free|pro|max|team|business|enterprise|edu|unknown): ", CLAUDE_PLAN_ENUM
    )
    observed_at = prompt_iso("Observed at (UTC YYYY-MM-DDTHH:MM:SS.mmmZ): ")
    observed_epoch = parse_iso(observed_at)
    if observed_epoch is None:
        raise ValueError("invalid input")
    expires_at = prompt_iso(
        "Expires at (UTC YYYY-MM-DDTHH:MM:SS.mmmZ): ",
        future_slack=None,
        after=observed_epoch,
        require_future=True,
    )
    count = prompt_integer("Number of usage windows (1-12): ", 1, 12)
    windows = []
    identities: set[tuple[str, int]] = set()
    for ordinal in range(1, count + 1):
        print(f"Window {ordinal}:", file=sys.stderr)
        for identity_attempt in range(PROMPT_RETRIES + 1):
            slot = prompt_enum("  Slot (primary|secondary): ", {"primary", "secondary"})
            used = prompt_integer("  Used percent (0-100): ", 0, 100)
            duration = prompt_integer("  Window duration in minutes: ", 1, MAX_SAFE_INTEGER // 60)
            reset_iso = prompt_iso(
                "  Resets at (UTC YYYY-MM-DDTHH:MM:SS.mmmZ): ",
                future_slack=None,
                require_future=True,
                whole_second=True,
            )
            identity = (slot, duration)
            if identity not in identities:
                identities.add(identity)
                break
            if identity_attempt < PROMPT_RETRIES:
                print("Window identity conflicts; enter the window again.", file=sys.stderr)
        else:
            raise ValueError("invalid input")
        reset_epoch = parse_iso(reset_iso, future_slack=None)
        if reset_epoch is None:
            raise ValueError("invalid input")
        windows.append({
            "slot": slot,
            "usedPercent": used,
            "windowDurationMins": duration,
            "resetsAt": int(reset_epoch),
        })
    raw = {
        "schema": "fm-plan-usage-manual.v1",
        "provider": "claude",
        "plan": plan,
        "observedAt": observed_at,
        "expiresAt": expires_at,
        "windows": windows,
    }
    projected = project_manual_claude(raw)
    if projected.get("status") != "manual" or projected.get("reason") != "manual_snapshot":
        raise ValueError("invalid input")
    data = (json.dumps(raw, separators=(",", ":"), sort_keys=True) + "\n").encode("utf-8")
    if len(data) > 16 * 1024:
        raise ValueError("too large")
    import secrets
    tmp = root / f".plan-usage-manual.{secrets.token_hex(16)}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(tmp, flags, 0o600)
    try:
        opened = os.fstat(fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_uid != os.geteuid()
            or opened.st_nlink != 1
        ):
            raise ValueError("unsafe staging")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        staged = tmp.lstat()
        if (
            not stat.S_ISREG(staged.st_mode)
            or staged.st_uid != os.geteuid()
            or staged.st_nlink != 1
            or (staged.st_dev, staged.st_ino) != (opened.st_dev, opened.st_ino)
        ):
            raise ValueError("unsafe staging")
        transaction = manual_private_dir(root)
        captured = transaction / target.name
        try:
            if target.exists() or target.is_symlink():
                os.rename(target, captured)
                current = captured.lstat()
            else:
                current = None
            if observed is None:
                if current is not None:
                    restore_manual_entry(captured, target)
                    raise ValueError("target appeared during import")
            elif (
                current is None
                or not stat.S_ISREG(current.st_mode)
                or current.st_uid != os.geteuid()
                or current.st_mode & 0o077
                or current.st_size < 0
                or current.st_size > 16 * 1024
                or (current.st_dev, current.st_ino) != (observed.st_dev, observed.st_ino)
            ):
                if current is not None:
                    restore_manual_entry(captured, target)
                raise ValueError("target changed during import")
            try:
                rename_noreplace(tmp, target)
            except BaseException:
                if current is not None:
                    restore_manual_entry(captured, target)
                raise
            if current is not None:
                captured.unlink()
        finally:
            try:
                transaction.rmdir()
            except OSError:
                pass
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def manual_plan_clear(config: Path) -> None:
    root = state_root(str(config))
    target = root / "plan-usage-manual.json"
    if not target.exists() and not target.is_symlink():
        return
    if target.parent.resolve(strict=True) != root or not contained(root, target):
        raise ValueError("outside root")
    transaction = manual_private_dir(root)
    captured_path = transaction / target.name
    os.rename(target, captured_path)
    try:
        captured = captured_path.lstat()
        if (
            stat.S_ISLNK(captured.st_mode)
            or not stat.S_ISREG(captured.st_mode)
            or captured.st_uid != os.geteuid()
            or captured_path.parent.resolve(strict=True) != transaction
            or not contained(root, captured_path)
            or captured_path.resolve(strict=True).parent != transaction
        ):
            raise ValueError("unsafe clear target")
        captured_path.unlink()
    except BaseException:
        try:
            restore_manual_entry(captured_path, target)
        finally:
            try:
                transaction.rmdir()
            except OSError:
                pass
        raise
    transaction.rmdir()


def snapshot_plan(root: Path, manual_enabled: bool, config: Path) -> dict[str, Any]:
    cache = cached_plan(root)
    if cache is not None and cache_usable(cache, 60):
        codex = cache
    else:
        lock = root / ".plan-usage.lock"
        flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(lock, flags, 0o600)
            os.fchmod(fd, 0o600)
        except OSError:
            fd = -1
        acquired = False
        if fd >= 0:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
            except BlockingIOError:
                acquired = False
        if not acquired:
            if cache is not None and cache_usable(cache, 15 * 60):
                codex = {**cache, "status": "stale", "reason": "source_error"}
            else:
                codex = unavailable_codex("source_error")
        else:
            source, reason = rpc_codex_plan()
            projected = project_plan(source) if source is not None else None
            if projected is not None and not windows_unexpired(projected):
                projected = None
                reason = "expired"
            if projected is not None:
                codex = projected
                try:
                    atomic_json(root / ".plan-usage-cache.json", root, codex, 64 * 1024)
                except (OSError, ValueError):
                    pass
            elif cache is not None and cache_usable(cache, 15 * 60):
                codex = {**cache, "status": "stale", "reason": reason or "source_error"}
            else:
                codex = unavailable_codex(reason or "unsupported_schema")
        if fd >= 0:
            if acquired:
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
    result = {
        "schema": "fm-plan-usage-snapshot.v1",
        "generatedAt": iso_from_epoch(now_epoch()),
        "providers": [codex, manual_claude_plan(config, manual_enabled)],
    }
    encoded = json.dumps(result, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 64 * 1024:
        result["providers"][0] = unavailable_codex("source_error")
    return result


def cleanup_task(root: Path, task_id: str) -> None:
    if not TASK_ID_RE.fullmatch(task_id):
        return
    stop_collector(root, task_id, remove_record=True)


def main(argv: list[str]) -> int:
    if not argv:
        return 2
    action = argv[0]
    try:
        if action == "worker-snapshot" and len(argv) == 2:
            print(json.dumps(snapshot_worker_bounded(state_root(argv[1])), separators=(",", ":")))
            return 0
        if action == "worker-init" and len(argv) == 4:
            root = state_root(argv[1])
            print(initialize_record(root, argv[2], argv[3]))
            return 0
        if action == "claude-status" and len(argv) == 4:
            root = state_root(argv[1])
            payload = sys.stdin.buffer.read(16 * 1024 + 1)
            claude_status_update(root, argv[2], argv[3], payload)
            return 0
        if action == "claude-start" and len(argv) == 4:
            root = state_root(argv[1])
            return 0 if start_collector(root, argv[2], Path(argv[3])) else 1
        if action == "claude-stop" and len(argv) == 3:
            cleanup_task(state_root(argv[1]), argv[2])
            return 0
        if action == "claude-collector" and len(argv) == 5:
            return collector_process(state_root(argv[1]), argv[2], Path(argv[3]), Path(argv[4]))
        if action == "claude-self-test" and len(argv) == 1:
            return 0 if claude_privacy_self_test() else 1
        if action == "plan-snapshot" and len(argv) == 4:
            enabled = argv[2] == "1"
            if argv[2] not in {"0", "1"}:
                return 2
            print(json.dumps(snapshot_plan(state_root(argv[1]), enabled, Path(argv[3])), separators=(",", ":")))
            return 0
        if action == "plan-manual-import" and len(argv) == 2:
            manual_plan_import(Path(argv[1]))
            return 0
        if action == "plan-manual-clear" and len(argv) == 2:
            manual_plan_clear(Path(argv[1]))
            return 0
    except (OSError, ValueError, json.JSONDecodeError, UnicodeError):
        return 1
    except Exception:
        # Public helpers expose only contract enums or a generic nonzero result.
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
