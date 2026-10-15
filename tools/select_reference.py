"""레퍼런스 후보 선정: 제목이 아니라 메타정보로 품질을 따져 장면(빗소리·기차·벽난로) 영상을 고른다.

사용법:
    python tools/select_reference.py --scene rain|train|fire [검색어] [--candidates 30] [--top 8] [--fetch]

1. 유튜브 검색 결과 N개의 메타데이터(조회수·좋아요·댓글 수·구독자·업로드일·길이·오디오 비트레이트)를 받는다.
2. 하드 필터: 길이(분석 구간을 담을 만큼), 라이브 제외, 제목·태그의 제외어(천둥, 음악 등 —
   엔진에 없는 소리가 섞인 레퍼런스는 피팅을 망친다), 장면 단어가 제목에 없는 영상(검색어와 다른 소리) 제외.
3. 메타 점수: 후보 집단 안에서 각 지표를 로그 스케일 z-점수로 바꿔 가중합.
     - 좋아요율 (베이지안 평활: 조회수가 적은 영상의 우연한 고비율을 깎음)   0.30
     - 조회수                                                              0.20
     - 하루당 조회수 (오래된 영상의 누적 이점 보정)                         0.10
     - 댓글율                                                              0.10
     - 채널 구독자                                                         0.10
     - 오디오 비트레이트 (128 kbps 미만 감점)                               0.05
4. 메타 점수 상위 --top개만 인기 댓글을 받아 품질 신호를 센다(댓글 수집은 느리다).
     감점: 광고·루프/반복·음악·천둥·가짜/AI·갑작스런 볼륨 언급 / 가점: 진짜 같은·잠·편안
   댓글 점수 0.15를 더해 최종 순위를 낸다.
결과는 reference/candidates_<장면>.json에 남기고, --fetch면 1위를 reference/<장면>_ref.wav로 내려받는다.
받은 구간은 소리 상태를 검사한다(audio_check): 너무 작은 녹음(RMS < −50 dBFS — 키우면 코덱 잡음이 드러난다)과
에너지 절반 이상이 30 Hz 아래인 녹음(마이크에 바람이 부딪히는 진동)은 버리고 다음 순위를 받는다.
장면마다 검색어와 제외어가 다르다(엔진에 없는 소리 — 음악, 다른 장면의 소리 — 가 섞이면 피팅을 망친다).
"""
import argparse
import json
import math
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fetch_reference import fetch, ytdlp_cmd  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MUSIC = r"music|음악|piano|피아노|lofi|lo-fi|jazz|재즈|guitar|meditation music|binaural|solfeggio|\bhz\b|asmr"
EXCLUDE = r"thunder|천둥|뇌우|번개|lightning|music|음악|piano|피아노|lofi|lo-fi|jazz|재즈|guitar|meditation music|" \
          r"binaural|solfeggio|\bhz\b|fireplace|벽난로|cafe|카페|ocean|파도|birds?\b|새소리"
SCENES = {
    "rain":  {"query": "rain on window sounds no thunder", "exclude": None},
    # 객실 안에서 듣는 주행음: 경적·안내방송·바깥 플랫폼 소리가 많은 영상은 뺀다
    "train": {"query": "train ride ambience sounds for sleeping no music",
              "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|blizzard|눈보라|horn|whistle|경적|"
                         r"station|\b역\b|announcement|안내|steam|증기|toy|model|crossing|건널목|subway|지하철|cartoon"},
    # 장작 타는 소리만: 비·바람·눈보라·음악이 함께 든 영상은 뺀다
    "fire":  {"query": "crackling fireplace sounds no music",
              "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|폭풍|\bwind\b|바람|blizzard|눈보라|snow|"
                         r"ocean|파도|birds?\b|새소리|cafe|카페|christmas|크리스마스|\bcats?\b|purr|고양이|study with me|reading|"
                         r"campfire.*(forest|night)"},
    # 졸졸 흐르는 개울: 새소리·비·폭포(굉음)·음악이 함께 든 영상은 뺀다
    "stream": {"require": r"stream|brook|creek|river|trickl|개울|시냇물|계곡", "query": "babbling brook stream water sounds for sleep no music",
               "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|birds?\b|birdsong|새소리|frogs?\b|개구리|"
                          r"waterfall|폭포|ocean|파도|\bwind\b|바람|fire|불|crickets?|귀뚜라미|night|cafe|카페"},
    # 바람만: 비·천둥·눈보라 속 사람 소리·벽난로·음악이 섞인 영상은 뺀다
    "wind": {"require": r"\bwind|바람", "query": "wind sounds for sleeping no music",
             "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|lightning|fire|벽난로|ocean|파도|sea|birds?\b|새소리|"
                        r"chimes?|풍경|tent|cabin|window|창문|train|기차|cafe|카페|crickets?|귀뚜라미"},
    # 여름밤 풀벌레: 개구리·부엉이·물소리·비·음악이 함께 든 영상은 뺀다
    "night": {"require": r"cricket|귀뚜라미|풀벌레", "query": "crickets chirping summer night sounds no music",
              "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|frogs?\b|개구리|owls?\b|부엉이|birds?\b|새소리|"
                         r"swamp|늪|stream|river|creek|개울|시냇물|campfire|fire|모닥불|ocean|파도|\bwind\b|바람|cicadas?|매미|cafe|카페"},
    # 아래 셋은 사건 없이 배경(베드)만 피팅하는 장면 — 화이트·핑크·브라운 노이즈에 가장 가까운 실제 소리
    # 샤워 물줄기(화이트에 가까운 밝은 쏴—): 'rain shower'가 걸리지 않게 비를 뺀다
    "shower": {"require": r"shower|샤워", "query": "shower sound for sleeping no music",
               "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|bath|bathtub|욕조|tub|baby|아기|"
                          r"singing|노래|fan|선풍기|hair ?dryer|드라이어|ocean|파도"},
    # 폭포(핑크에 가까운 넓은 물소리): 새소리·비·음악이 섞인 영상은 뺀다
    "waterfall": {"require": r"waterfall|폭포|\bfalls\b", "query": "waterfall sounds for sleeping no music",
                  "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|birds?\b|birdsong|새소리|"
                             r"frogs?\b|개구리|crickets?|귀뚜라미|forest|숲|jungle|ocean|파도|wind\b|바람"},
    # 선풍기(브라운에 가까운 낮은 바람 소리): 다른 가전·물소리가 섞인 영상은 뺀다
    "fan": {"require": r"\bfans?\b|선풍기", "query": "fan noise for sleeping no music",
            "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|thunder|천둥|hair ?dryer|드라이어|vacuum|청소기|washing|세탁기|"
                       r"dryer|건조기|shower|샤워|ocean|파도|baby|아기|heartbeat|심장|airplane|비행기|car\b|자동차"},
    # 아래 둘은 실내 장면: 조용한 배경 + 사람의 활동(필기·책장 / 타이핑·먼 대화)
    # 독서실·도서관: 카페·비·벽난로·판타지 배경(음악이 섞임)이 함께 든 영상은 뺀다
    "study": {"require": r"library|study room|reading room|독서실|도서관|열람실", "query": "library ambience sounds for studying pages turning writing no music",
              "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|fire|벽난로|모닥불|cafe|café|카페|coffee|커피|"
                         r"ocean|파도|harry potter|hogwarts|호그와트|magic|마법|medieval|fantasy|ancient|dark academia|castle|"
                         r"christmas|크리스마스|snow|cats?\b|고양이|night|밤"},
    # 사무실: 비·카페·음악·드라마('The Office')가 섞인 영상은 뺀다
    "office": {"require": r"office|사무실|workplace|coworking", "query": "office ambience background noise typing people talking no music",
               "exclude": MUSIC + r"|\brain(?:y|ing|s)?\b|빗소리|\b비\b|thunder|천둥|storm|fire|벽난로|cafe|café|카페|coffee shop|커피|"
                          r"ocean|파도|the office|dunder|michael scott|anime|애니|sci-?fi|spaceship|cyberpunk|christmas|크리스마스|"
                          r"night|밤|haunted|horror|animal crossing|acnh|동물의 ?숲|suits|harvey|tv ambience|game"},
}
# "No Thunder", "NO ADS NO MUSIC", "천둥 없는" 같은 부정 표현은 매칭 전에 지운다
NEGATED = re.compile(r"\b(?:no|without|zero|w/o)\s+(?:[\w-]+\s*(?:[,&/+]|and|or)?\s*){0,1}?"
                     r"(?:thunder\w*|music|ads?|lightning|talking|voice|loops?|rain|wind|horns?)\b|(?:천둥|음악|광고)\s*(?:없는|없이|x)", re.I)


def rms_db(wav, af=""):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", str(wav), "-af", af + "astats=measure_perchannel=none",
                        "-f", "null", "-"], capture_output=True, text=True, encoding="utf-8", errors="replace")
    m = re.findall(r"RMS level dB: (-?[\d.]+|-inf)", r.stderr)
    return float(m[-1]) if m and m[-1] != "-inf" else -200.0


def audio_check(wav):
    """받은 구간의 소리 상태: 문제가 있으면 이유, 괜찮으면 None."""
    full = rms_db(wav)
    if full < -50:
        return f"너무 작은 녹음 (RMS {full:.1f} dBFS)"
    above = rms_db(wav, "highpass=f=30,highpass=f=30,")
    infra = 1 - 10 ** ((above - full) / 10)
    if infra > 0.5:
        return f"30 Hz 아래 에너지 {infra * 100:.0f}% (마이크 바람 진동)"
    return None


def strip_negated(text):
    return NEGATED.sub(" ", text)
NEG = r"\bads?\b|광고|commercial|mid-?roll|loop|루프|반복|music|음악|thunder|천둥|fake|가짜|\bai\b|" \
      r"sudden|갑자기|too loud|volume|볼륨|static|지직|noise floor|cuts? off|끊"
POS = r"\breal\b|realistic|진짜|실제|sleep|잠|숙면|relax|편안|calm|cozy|best|최고|perfect|완벽|study|공부"
WEIGHTS = {"like_rate": .30, "views": .20, "velocity": .10, "comment_rate": .10, "followers": .10, "audio": .05}
W_COMMENTS = .15


def run_json(args, timeout=120):
    js = ["--js-runtimes", "node"] if shutil.which("node") else []
    r = subprocess.run(ytdlp_cmd() + js + args, capture_output=True, text=True, encoding="utf-8", timeout=timeout)
    if r.returncode:
        raise RuntimeError(r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "yt-dlp 실패")
    return json.loads(r.stdout)


def search(query, n):
    res = run_json(["--flat-playlist", "--dump-single-json", f"ytsearch{n}:{query}"])
    return [e["id"] for e in res.get("entries", []) if e.get("id")]


CACHE = ROOT / "reference/.meta_cache"


def metadata(vid):
    """영상 메타데이터. 같은 날 다시 돌릴 때는 reference/.meta_cache의 사본을 쓴다."""
    cached = CACHE / f"{vid}.{date.today():%Y%m%d}.json"
    if cached.exists():
        return json.loads(cached.read_text(encoding="utf-8"))
    try:
        m = run_json(["--dump-single-json", "--skip-download", "--no-playlist", f"https://www.youtube.com/watch?v={vid}"])
        CACHE.mkdir(parents=True, exist_ok=True)
        m.pop("automatic_captions", None); m.pop("subtitles", None); m.pop("thumbnails", None)
        cached.write_text(json.dumps(m, ensure_ascii=False), encoding="utf-8")
        return m
    except Exception as e:  # 비공개·지역 제한 등은 후보에서 뺀다
        print(f"  {vid}: 메타데이터 실패 ({e})", file=sys.stderr)
        return None


def comments(vid, n):
    """인기 댓글 본문. 수집 결과가 실행마다 조금씩 달라 순위가 흔들리지 않도록 같은 날은 캐시를 쓴다."""
    cached = CACHE / f"{vid}.{date.today():%Y%m%d}.comments{n}.json"
    if cached.exists():
        return json.loads(cached.read_text(encoding="utf-8"))
    m = run_json(["--dump-single-json", "--skip-download", "--write-comments", "--no-playlist",
                  "--extractor-args", f"youtube:max_comments={n},{n},0,0;comment_sort=top",
                  f"https://www.youtube.com/watch?v={vid}"], timeout=300)
    texts = [c.get("text", "") for c in (m.get("comments") or [])]
    CACHE.mkdir(parents=True, exist_ok=True)
    cached.write_text(json.dumps(texts, ensure_ascii=False), encoding="utf-8")
    return texts


def comment_signal(texts):
    """인기 댓글에서 품질 언급 비율: (가점 − 2×감점) / 댓글 수. 감점 키워드를 무겁게 본다."""
    if not texts:
        return 0.0, 0, 0
    pos = sum(bool(re.search(POS, t, re.I)) for t in texts)
    neg = sum(bool(re.search(NEG, strip_negated(t), re.I)) for t in texts)
    return (pos - 2 * neg) / len(texts), pos, neg


def features(m):
    v = m.get("view_count") or 0
    likes = m.get("like_count") or 0
    cm = m.get("comment_count") or 0
    up = m.get("upload_date")
    age = max(30, (date.today() - datetime.strptime(up, "%Y%m%d").date()).days) if up else 365
    abr = max([f.get("abr") or 0 for f in m.get("formats", []) if f.get("vcodec") == "none"] or [0])
    # 베이지안 평활 좋아요율: 사전 1%를 조회수 5000회 분량으로 섞는다
    like_rate = (likes + 0.01 * 5000) / (v + 5000)
    return {
        "views": math.log10(v + 1),
        "like_rate": math.log10(like_rate),
        "velocity": math.log10(v / age + 1),
        "comment_rate": math.log10((cm + 1) / (v + 1000)),
        "followers": math.log10((m.get("channel_follower_count") or 0) + 1),
        "audio": min(abr, 160) / 160 - (0.5 if abr and abr < 128 else 0),
    }


def zscores(rows, key):
    xs = [r["f"][key] for r in rows]
    mu = sum(xs) / len(xs)
    sd = math.sqrt(sum((x - mu) ** 2 for x in xs) / len(xs)) or 1
    for r in rows:
        r["z"][key] = (r["f"][key] - mu) / sd


def select(query, n, top, need_s, n_comments, exclude, scene="rain", require=None):
    print(f"검색: '{query}' 상위 {n}개")
    ids = search(query, n)
    with ThreadPoolExecutor(6) as ex:
        metas = [m for m in ex.map(metadata, ids) if m]

    rows, dropped = [], []
    for m in metas:
        text = strip_negated(m.get("title", ""))      # 태그는 검색 노출용 단어가 많아 제목만 본다
        why = ("라이브" if m.get("is_live") or m.get("was_live") else
               f"길이 {m.get('duration') or 0}s < {need_s}s" if (m.get("duration") or 0) < need_s else
               f"제외어 '{re.search(exclude, text, re.I).group(0)}'" if re.search(exclude, text, re.I) else
               "제목에 장면 단어 없음" if require and not re.search(require, text, re.I) else None)
        (dropped if why else rows).append({"m": m, "why": why, "f": {}, "z": {}})
    for d in dropped:
        print(f"  제외: {d['m'].get('title', '')[:60]} — {d['why']}")
    if not rows:
        sys.exit("조건을 통과한 후보가 없습니다. 검색어나 --exclude를 바꿔 보세요.")

    for r in rows:
        r["f"] = features(r["m"])
    for k in WEIGHTS:
        zscores(rows, k)
    for r in rows:
        r["meta_score"] = sum(w * r["z"][k] for k, w in WEIGHTS.items())
    rows.sort(key=lambda r: -r["meta_score"])

    # 인기 댓글 품질 신호 (상위 후보만)
    print(f"인기 댓글 수집: 상위 {min(top, len(rows))}개 × 최대 {n_comments}개")
    with ThreadPoolExecutor(4) as ex:
        sigs = list(ex.map(lambda r: comment_signal(comments(r["m"]["id"], n_comments)), rows[:top]))
    for r, (s, pos, neg) in zip(rows, sigs):
        r["comments"] = {"signal": round(s, 3), "positive": pos, "negative": neg}
    cs = [r["comments"]["signal"] for r in rows[:top]]
    mu = sum(cs) / len(cs)
    sd = math.sqrt(sum((x - mu) ** 2 for x in cs) / len(cs)) or 1
    for r in rows:
        zc = (r["comments"]["signal"] - mu) / sd if "comments" in r else -1.0   # 댓글을 못 본 후보는 불리하게
        r["score"] = r["meta_score"] + W_COMMENTS * zc
    rows.sort(key=lambda r: -r["score"])

    print(f"\n{'순위':>2} {'점수':>6} {'조회수':>9} {'좋아요율':>7} {'댓글':>6} {'구독자':>8} {'kbps':>4} {'댓글신호':>7}  제목")
    for i, r in enumerate(rows, 1):
        m, c = r["m"], r.get("comments")
        lr = (m.get("like_count") or 0) / max(1, m.get("view_count") or 0) * 100
        print(f"{i:>4} {r['score']:+6.2f} {m.get('view_count') or 0:>9,} {lr:6.2f}% {m.get('comment_count') or 0:>6,} "
              f"{m.get('channel_follower_count') or 0:>8,} {r['f']['audio'] * 160:>4.0f} "
              f"{format(c['signal'], '+.2f') if c else '-':>7}  {m.get('title', '')[:50]}")

    out = ROOT / f"reference/candidates_{scene}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    summary = [{"rank": i, "id": r["m"]["id"], "title": r["m"].get("title"), "channel": r["m"].get("channel"),
                "url": r["m"].get("webpage_url"), "duration_s": r["m"].get("duration"),
                "views": r["m"].get("view_count"), "likes": r["m"].get("like_count"),
                "comment_count": r["m"].get("comment_count"), "followers": r["m"].get("channel_follower_count"),
                "upload_date": r["m"].get("upload_date"), "score": round(r["score"], 3),
                "meta_score": round(r["meta_score"], 3), "comments": r.get("comments"),
                "z": {k: round(v, 2) for k, v in r["z"].items()}}
               for i, r in enumerate(rows, 1)]
    out.write_text(json.dumps({"query": query, "weights": {**WEIGHTS, "comments": W_COMMENTS},
                               "candidates": summary, "excluded": [{"title": d["m"].get("title"), "why": d["why"]} for d in dropped]},
                              ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n저장: {out.relative_to(ROOT)}")
    return summary


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("query", nargs="?", help="검색어(생략하면 장면 기본값)")
    ap.add_argument("--scene", choices=SCENES, default="rain")
    ap.add_argument("--candidates", type=int, default=30, help="검색 결과 몇 개를 볼지")
    ap.add_argument("--top", type=int, default=8, help="댓글까지 볼 상위 후보 수")
    ap.add_argument("--comments", type=int, default=60, help="후보당 인기 댓글 수")
    ap.add_argument("--start", type=int, default=300, help="분석 구간 시작(초). 인트로·아웃트로를 피한다")
    ap.add_argument("--duration", type=int, default=180)
    ap.add_argument("--exclude", help="제목 제외 정규식(생략하면 장면 기본값)")
    ap.add_argument("--fetch", action="store_true", help="1위를 reference/<장면>_ref.wav로 내려받기")
    a = ap.parse_args()
    sc = SCENES[a.scene]
    ranked = select(a.query or sc["query"], a.candidates, a.top, a.start + a.duration + 60, a.comments,
                    a.exclude or sc["exclude"] or EXCLUDE, a.scene, sc.get("require"))
    print(f"1위: {ranked[0]['title']} ({ranked[0]['url']})")
    if a.fetch:
        # 스트림이 막힌 영상(HTTP 403 등)은 건너뛰고 다음 순위를 받는다
        for best in ranked[:5]:
            try:
                wav = fetch(best["url"], a.start, a.duration, ROOT / f"reference/{a.scene}_ref.wav")
                bad = audio_check(wav)
                if not bad:
                    break
                print(f"  {best['rank']}위 소리 상태 불량({bad}) → 다음 후보", file=sys.stderr)
            except (subprocess.CalledProcessError, SystemExit) as e:
                print(f"  {best['rank']}위 다운로드 실패({e}) → 다음 후보", file=sys.stderr)
        else:
            sys.exit("상위 5개 후보 중 쓸 수 있는 레퍼런스가 없습니다.")
        meta = wav.with_suffix(".json")
        info = json.loads(meta.read_text(encoding="utf-8"))
        info["selection"] = {k: best[k] for k in ("rank", "score", "views", "likes", "comment_count", "followers", "comments")}
        meta.write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
