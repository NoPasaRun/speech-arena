#!/usr/bin/env python3
"""Eval runner for the rapport/psychotype-fit judge prompt (see cases.json).

Usage:
    python3 runner.py --variant baseline --model claude-haiku-4-5 --reps 2
    python3 runner.py --variant v1 --model claude-sonnet-5 --reps 2

Writes into <variant>/results.jsonl, <variant>/traces/<id>_rep<k>.json,
<variant>/errors.jsonl. Idempotent per (case, rep): re-running skips rows
already present in results.jsonl.
"""
import argparse
import asyncio
import json
import random
import re
import sys
import time
from pathlib import Path

import anthropic

FLOW_DIR = Path(__file__).parent
MAX_CONCURRENCY = 6
WALL_CLOCK_CEILING_SEC = 30.0
MAX_RETRIES = 4

SYSTEM_PROMPT = """\
Ты — судья-психолог для видеоигры. Тебе дан психологический портрет NPC (веса \
от 0 до 3 по каждому из четырёх темпераментов: сангвиник, холерик, флегматик, \
меланхолик — чем выше вес, тем сильнее выражена черта), контекст сцены и реплика \
или действие игрока. Оцени, насколько реплика/действие в данном контексте \
расположило бы к игроку NPC именно с таким психотипом.

Черты темпераментов:
- Сангвиник: общительный, любит лёгкость и юмор, скучает от сухости и занудства.
- Холерик: напористый, ценит уверенность и инициативу, не любит нерешительность \
и заискивание.
- Флегматик: спокойный, ценит тепло и стабильность, не любит спешку и давление.
- Меланхолик: чувствительный, ценит искренность и глубину, не любит \
поверхностность и пафос.

Учитывай ВСЕ веса психотипа пропорционально (не только доминирующий), а также \
контекст: окружение сцены и недавние действия игрока могут усиливать или \
полностью обесценивать даже хорошо сформулированную реплику.

Физическая дистанция — самостоятельный сигнал, не менее важный чем текст \
реплики. Сокращение дистанции соразмерно ситуации читается как уверенность \
(нравится холерику и сангвинику, если не резко и не грубо); чрезмерная или \
растущая дистанция при попытке заговорить или подсесть — как нерешительность \
и незаинтересованность, даже если сама фраза вежливая и дружелюбная (портит \
впечатление в первую очередь сангвинику и холерику). Резкое вторжение в \
личное пространство без повода — наоборот, нарушение границ.

Если игрок повторяет уже проигнорированную попытку, не меняя ни дистанцию, \
ни тон, ни подход — это читается как невнимательность к реакции NPC. Для \
большинства психотипов это раздражает или отталкивает сильнее, чем сама \
первая неудачная попытка, а не интригует.

Ответь СТРОГО в этом текстовом формате, три строки, без markdown и без JSON:
RAPPORT: <целое число от -3 до 3>
ENDS_SCENE: <true или false — true только если реплика/действие настолько \
неуместны (грубость, нарушение личных границ, откровенная ложь на месте, \
публичное унижение), что NPC немедленно обрывает контакт>
ПРИЧИНА: <короткое объяснение на русском, одно предложение>\
"""


def build_user_message(case: dict) -> str:
    p = case["npc_psychotype"]
    lines = [
        f"Психотип NPC: сангвиник={p['sanguine']}, холерик={p['choleric']}, "
        f"флегматик={p['phlegmatic']}, меланхолик={p['melancholic']}",
        f"Окружение: {', '.join(case['environment']) or '(не указано)'}",
    ]
    if case.get("prior_exchange"):
        lines.append("Предыдущий обмен репликами:")
        for turn in case["prior_exchange"]:
            who = "Игрок" if turn["speaker"] == "player" else "NPC"
            lines.append(f"  {who}: {turn['text']}")
    if case.get("player_actions"):
        lines.append(f"Действия игрока в этот момент: {', '.join(case['player_actions'])}")
    lines.append(f'Реплика/стратегия игрока: "{case["player_line"]}"')
    return "\n".join(lines)


def parse_response(text: str) -> dict:
    rapport_match = re.search(r"RAPPORT\s*:\s*(-?\d+)", text, re.IGNORECASE)
    ends_match = re.search(r"ENDS_SCENE\s*:\s*(true|false)", text, re.IGNORECASE)
    reason_match = re.search(r"ПРИЧИНА\s*:\s*(.+)", text, re.IGNORECASE | re.DOTALL)
    if rapport_match is None or ends_match is None:
        raise ValueError(f"не удалось разобрать ответ модели: {text!r}")
    rapport = int(rapport_match.group(1))
    ends_scene = ends_match.group(1).lower() == "true"
    reason = reason_match.group(1).strip() if reason_match else ""
    return {"rapport": rapport, "ends_scene": ends_scene, "reason": reason}


def grade(case: dict, parsed: dict) -> dict:
    err = abs(parsed["rapport"] - case["expected_rapport_delta"])
    return {
        "delta_ok": 1 if err <= 1 else 0,
        "ends_ok": 1 if parsed["ends_scene"] == case["expected_ends_scene"] else 0,
        "delta_err": err,
    }


def load_cases() -> list:
    return json.loads((FLOW_DIR / "cases.json").read_text())


def already_done(results_path: Path) -> set:
    done = set()
    if results_path.exists():
        for line in results_path.read_text().splitlines():
            if not line.strip():
                continue
            row = json.loads(line)
            done.add((row["prompt_id"], row.get("rep", 0)))
    return done


async def run_one(client: anthropic.AsyncAnthropic, model: str, case: dict, rep: int,
                   sem: asyncio.Semaphore, results_f, errors_f, traces_dir: Path):
    async with sem:
        user_msg = build_user_message(case)
        attempt = 0
        start = time.monotonic()
        while True:
            attempt += 1
            try:
                kwargs = dict(
                    model=model,
                    max_tokens=300,
                    system=SYSTEM_PROMPT,
                    messages=[{"role": "user", "content": user_msg}],
                )
                if "sonnet" in model or "opus" in model:
                    # Sonnet 5 / Opus run adaptive thinking by default; on a
                    # short classification task max_tokens=300 can be spent
                    # entirely on thinking, leaving no room for the answer
                    # (empty content, stop_reason=max_tokens). Not needed here.
                    kwargs["thinking"] = {"type": "disabled"}
                response = await asyncio.wait_for(
                    client.messages.create(**kwargs),
                    timeout=WALL_CLOCK_CEILING_SEC,
                )
                break
            except asyncio.TimeoutError:
                errors_f.write(json.dumps({
                    "prompt_id": case["id"], "rep": rep, "failure_class": "timeout",
                    "attempt": attempt,
                }, ensure_ascii=False) + "\n")
                errors_f.flush()
                return
            except anthropic.RateLimitError:
                if attempt > MAX_RETRIES:
                    errors_f.write(json.dumps({
                        "prompt_id": case["id"], "rep": rep, "failure_class": "rate_limit_exhausted",
                        "attempt": attempt,
                    }, ensure_ascii=False) + "\n")
                    errors_f.flush()
                    return
                await asyncio.sleep(min(2 ** attempt, 20) + random.uniform(0, 1))
                continue
            except anthropic.APIStatusError as exc:
                if exc.status_code >= 500 and attempt <= MAX_RETRIES:
                    await asyncio.sleep(min(2 ** attempt, 20) + random.uniform(0, 1))
                    continue
                errors_f.write(json.dumps({
                    "prompt_id": case["id"], "rep": rep, "failure_class": "harness_or_serving_error",
                    "attempt": attempt, "detail": str(exc),
                }, ensure_ascii=False) + "\n")
                errors_f.flush()
                return

        latency_s = time.monotonic() - start
        served_model = response.model
        text = "".join(b.text for b in response.content if b.type == "text")

        try:
            parsed = parse_response(text)
        except ValueError as exc:
            errors_f.write(json.dumps({
                "prompt_id": case["id"], "rep": rep, "failure_class": "unparseable_output",
                "attempt": attempt, "detail": str(exc), "model": served_model,
                "usage": {
                    "input_tokens": response.usage.input_tokens,
                    "output_tokens": response.usage.output_tokens,
                },
            }, ensure_ascii=False) + "\n")
            errors_f.flush()
            return

        g = grade(case, parsed)
        row = {
            "prompt_id": case["id"],
            "rep": rep,
            "prompt": user_msg,
            "tags": case["tags"],
            "stop_reason": response.stop_reason,
            "status": "truncated" if response.stop_reason == "max_tokens" else "ok",
            "grade": g,
            "explanation": {"delta_ok": parsed["reason"], "ends_ok": parsed["reason"]},
            "model": served_model,
            "usage": {
                "input_tokens": response.usage.input_tokens,
                "output_tokens": response.usage.output_tokens,
                "cache_read_input_tokens": getattr(response.usage, "cache_read_input_tokens", 0) or 0,
                "cache_creation_input_tokens": getattr(response.usage, "cache_creation_input_tokens", 0) or 0,
            },
            "perf": {"latency_s": round(latency_s, 3), "attempts": attempt},
            "meta": {
                "predicted_rapport": parsed["rapport"],
                "expected_rapport": case["expected_rapport_delta"],
                "predicted_ends_scene": parsed["ends_scene"],
                "expected_ends_scene": case["expected_ends_scene"],
            },
        }
        results_f.write(json.dumps(row, ensure_ascii=False) + "\n")
        results_f.flush()

        trace = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_msg},
            {"role": "assistant", "content": text},
        ]
        (traces_dir / f"{case['id']}_rep{rep}.json").write_text(
            json.dumps(trace, ensure_ascii=False, indent=2)
        )


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--variant", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--reps", type=int, default=1)
    ap.add_argument("--limit", type=int, default=None, help="only run the first N cases (pilot)")
    args = ap.parse_args()

    variant_dir = FLOW_DIR / args.variant
    traces_dir = variant_dir / "traces"
    traces_dir.mkdir(parents=True, exist_ok=True)
    results_path = variant_dir / "results.jsonl"
    errors_path = variant_dir / "errors.jsonl"

    cases = load_cases()
    if args.limit:
        cases = cases[:args.limit]

    done = already_done(results_path)
    todo = [(c, r) for c in cases for r in range(args.reps) if (c["id"], r) not in done]
    print(f"{len(cases)} cases x {args.reps} reps = {len(cases) * args.reps} total, "
          f"{len(done)} already done, {len(todo)} to run", file=sys.stderr)

    client = anthropic.AsyncAnthropic()
    sem = asyncio.Semaphore(MAX_CONCURRENCY)

    with open(results_path, "a") as results_f, open(errors_path, "a") as errors_f:
        tasks = [
            run_one(client, args.model, case, rep, sem, results_f, errors_f, traces_dir)
            for case, rep in todo
        ]
        for i, fut in enumerate(asyncio.as_completed(tasks), 1):
            await fut
            if i % 10 == 0 or i == len(tasks):
                print(f"  {i}/{len(tasks)} done", file=sys.stderr)

    print(f"wrote {results_path}", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())
