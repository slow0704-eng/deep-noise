"""레퍼런스 빗소리 수집: 유튜브 영상의 일부 구간을 48 kHz WAV로 내려받는다.

사용법:
    python tools/fetch_reference.py URL [--start 60] [--duration 180] [-o reference/rain_ref.wav]

yt-dlp(CLI 또는 모듈)와 ffmpeg가 필요하다. 받은 음원은 분석용으로만 쓰고
저장소에는 올리지 않는다(reference/는 .gitignore 대상). 메타데이터는 같은 이름의 .json으로 남긴다.
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


def ytdlp_cmd():
    exe = shutil.which("yt-dlp")
    return [exe] if exe else [sys.executable, "-m", "yt_dlp"]


def fetch(url, start, duration, out):
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    if not shutil.which("ffmpeg"):
        sys.exit("ffmpeg를 찾을 수 없습니다. PATH에 ffmpeg를 추가해 주세요.")

    meta = json.loads(subprocess.run(
        ytdlp_cmd() + ["--dump-single-json", "--no-playlist", "--skip-download", url],
        check=True, capture_output=True, text=True, encoding="utf-8").stdout)

    end = start + duration
    if meta.get("duration") and end > meta["duration"]:
        sys.exit(f"구간 {start}–{end}s가 영상 길이 {meta['duration']}s를 넘습니다.")

    js = ["--js-runtimes", "node"] if shutil.which("node") else []
    out.unlink(missing_ok=True)
    download_and_trim(url, js, start, duration, out)
    if not out.exists():
        sys.exit(f"변환은 끝났지만 {out}을 찾지 못했습니다.")
    return finish(meta, url, start, duration, out)


def to_wav(src, start, duration, out):
    """ffmpeg로 구간만 잘라 48 kHz / 16-bit / 스테레오 WAV로 변환."""
    return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                           "-ss", str(start), "-t", str(duration), "-i", str(src),
                           "-ar", "48000", "-ac", "2", "-c:a", "pcm_s16le", str(out)], timeout=600).returncode == 0


def download_and_trim(url, js, start, duration, out):
    # yt-dlp의 --download-sections는 스트림을 실시간 속도로 읽어 느리므로,
    # 원본 오디오를 통째로 받은 뒤 ffmpeg로 구간만 자른다.
    src_tmpl = str(out.parent / f"_src_{out.stem}.%(ext)s")   # 장면마다 따로(동시에 받아도 겹치지 않게)
    subprocess.run(ytdlp_cmd() + js + ["--no-playlist", "-f", "bestaudio", "--force-overwrites",
                                       "--no-progress", "-o", src_tmpl, url], check=True)
    srcs = [p for p in out.parent.glob(f"_src_{out.stem}.*") if p.suffix not in (".part", ".ytdl")]
    if not srcs:
        sys.exit("원본 오디오를 받지 못했습니다.")
    src = srcs[0]
    try:
        to_wav(src, start, duration, out)
    finally:
        src.unlink(missing_ok=True)


def finish(meta, url, start, duration, out):
    info = {
        "url": meta.get("webpage_url", url),
        "id": meta.get("id"),
        "title": meta.get("title"),
        "channel": meta.get("channel") or meta.get("uploader"),
        "start_s": start,
        "duration_s": duration,
    }
    out.with_suffix(".json").write_text(json.dumps(info, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"저장: {out} ({out.stat().st_size / 1e6:.1f} MB) — {info['title']}")
    return out


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # Windows 콘솔(cp949)에서도 출력이 깨지지 않게
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url")
    ap.add_argument("--start", type=int, default=60, help="시작 시각(초). 인트로를 피하려고 기본 60초")
    ap.add_argument("--duration", type=int, default=180, help="길이(초)")
    ap.add_argument("-o", "--out", default="reference/rain_ref.wav")
    a = ap.parse_args()
    fetch(a.url, a.start, a.duration, a.out)
