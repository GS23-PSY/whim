"""
main.py — whim_route_engine + api_adapter 연동 실행 스크립트 (청주 성안길 일대 8곳)

  python main.py                      # 도보, 캐시 정밀도 4자리
  python main.py --mode best          # 가까우면 도보, 멀면 도보/대중교통 중 짧은 쪽
  python main.py --precision 3 --runs 2   # 2회차에서 캐시 적중 확인
  python main.py --redis redis://localhost:6379/0
  python main.py --no-geocode         # 카카오 로컬 검색으로 좌표 보정하지 않음

KAKAO_REST_API_KEY는 .env에서 읽는다. 키가 없거나 API가 죽어도 Haversine 폴백으로 코스는 나온다.
"""

import argparse
import asyncio
import logging
import sys
from typing import Optional

import aiohttp

from whim_route_engine import Place, Trip, build_time_matrix, estimate_walk_minutes, hm, render, solve
from api_adapter import (AdapterConfig, KakaoTimeMatrixProvider, MatrixResult, MemoryLRUCache, Mode,
                         RedisCache, api_key_from_env, build_real_time_matrix, haversine_km,
                         kakao_error_detail, trip_points)

log = logging.getLogger("whim.main")

# 출발지: 청주 상당공원. 좌표는 근사값이며, 키가 있으면 카카오 로컬 키워드 검색으로 실좌표로 보정한다.
START = ("청주 상당공원", 36.6389, 127.4907)

# (검색어, 표시명, lat, lon, 영업구간, 체류분, 점수)
# 검색어는 문자열 또는 튜플. 튜플이면 앞에서부터 시도해 처음 결과가 나온 질의어를 쓴다.
PLACES = [
    ("용두사지 철당간",       "철당간",          36.6347, 127.4889, [("00:00", "23:59")], 20, 1.0),
    ("청주 중앙공원",         "중앙공원",        36.6361, 127.4868, [("00:00", "23:59")], 30, 0.8),
    ("청주 성안길",           "성안길 쇼핑",     36.6356, 127.4896, [("10:30", "22:00")], 50, 1.2),
    ("육거리종합시장",        "육거리시장",      36.6284, 127.4902, [("08:00", "20:00")], 45, 1.5),
    # 브레이크타임 있는 식당 — 윈도우 2개
    # '서문시장 삼겹살거리'는 카카오 로컬에 등록된 장소명이 아니어서 결과 0건 → 시장 이름으로 대체
    (("서문시장", "청주 서문시장", "서문시장 삼겹살거리"), "서문 삼겹살거리", 36.6338, 127.4843, [("11:30", "14:30"), ("17:00", "22:00")], 60, 2.0),
    ("청주 청녕각",           "청녕각",          36.6376, 127.4893, [("09:00", "18:00")], 20, 0.7),
    ("수암골",                "수암골",          36.6436, 127.4957, [("00:00", "23:59")], 40, 1.3),
    ("국립청주박물관",        "국립청주박물관",  36.6566, 127.5007, [("09:00", "18:00")], 60, 1.0),
]

KAKAO_LOCAL_KEYWORD = "https://dapi.kakao.com/v2/local/search/keyword.json"


def build_trip() -> Trip:
    places = [Place(name, lat, lon, [(hm(o), hm(c)) for o, c in win], dwell, score=score)
              for _, name, lat, lon, win, dwell, score in PLACES]
    return Trip(start_lat=START[1], start_lon=START[2],
                start_time=hm("13:00"), end_time=hm("20:00"), places=places)


async def geocode_trip(trip: Trip, api_key: str) -> int:
    """카카오 로컬 키워드 검색으로 좌표를 실측값으로 보정. 실패한 장소는 근사 좌표를 유지한다. 반환: 성공 개수."""
    headers = {"Authorization": f"KakaoAK {api_key}"}
    timeout = aiohttp.ClientTimeout(total=3)
    names = ["출발지"] + [p.name for p in trip.places]
    queries = [START[0]] + [q for q, *_ in PLACES]
    queries = [q if isinstance(q, tuple) else (q,) for q in queries]

    async with aiohttp.ClientSession(headers=headers, timeout=timeout) as s:
        async def search(q: str, lat: float, lon: float) -> Optional[dict]:
            params = {"query": q, "x": f"{lon}", "y": f"{lat}", "radius": 3000, "size": 1}
            try:
                async with s.get(KAKAO_LOCAL_KEYWORD, params=params) as r:
                    if r.status in (401, 403):
                        detail = await kakao_error_detail(r)
                        log.error("카카오 로컬 API 인증/권한 오류 HTTP %d — %s", r.status, detail)
                        raise PermissionError(detail)
                    if r.status != 200:
                        log.warning("로컬 검색 '%s' HTTP %d — %s", q, r.status, await kakao_error_detail(r))
                        return None
                    docs = (await r.json(content_type=None)).get("documents") or []
                    return docs[0] if docs else None
            except PermissionError:
                raise
            except Exception as e:
                log.warning("로컬 검색 '%s' 실패: %r", q, e)
                return None

        async def one(cands: tuple, lat: float, lon: float) -> Optional[tuple]:
            for q in cands:                          # 후보 질의어를 순서대로 시도
                doc = await search(q, lat, lon)
                if doc:
                    return q, doc
            return None

        coords = [(trip.start_lat, trip.start_lon)] + [(p.lat, p.lon) for p in trip.places]
        found = await asyncio.gather(*(one(c, *xy) for c, xy in zip(queries, coords)),
                                     return_exceptions=True)

    if any(isinstance(f, PermissionError) for f in found):
        print("[geocode] 인증/권한 오류로 좌표 보정 중단 — 근사 좌표 사용 (원인은 위 ERROR 로그)")
        return 0

    ok = 0
    for idx, (name, cands, (lat, lon), f) in enumerate(zip(names, queries, coords, found)):
        if not f or isinstance(f, BaseException):
            print(f"[geocode] ✗ {name}: 후보 {list(cands)} 모두 결과 없음 → 근사 좌표 유지")
            continue
        q, doc = f
        new_lat, new_lon = float(doc["y"]), float(doc["x"])
        moved = haversine_km(lat, lon, new_lat, new_lon) * 1000
        alt = "" if q == cands[0] else f" (대체 질의어)"
        print(f"[geocode] ✓ {name} ← '{q}'{alt} → {doc['place_name']} · {doc.get('road_address_name') or doc.get('address_name')} · {moved:.0f}m 보정")
        if idx == 0:
            trip.start_lat, trip.start_lon = new_lat, new_lon
        else:
            trip.places[idx - 1].lat, trip.places[idx - 1].lon = new_lat, new_lon
        ok += 1
    print(f"[geocode] {ok}/{len(found)}곳 카카오 로컬 좌표로 보정")
    return ok


def print_matrix(trip: Trip, res: MatrixResult) -> None:
    mark = {"api": " ", "cache": "c", "fallback": "*", "near": "~", "self": " "}
    labels = ["출발"] + [p.name[:4] for p in trip.places]
    print("       " + "".join(f"{i:>5}" for i in range(len(labels))))
    for i, row in enumerate(res.matrix):
        cells = "".join(f"{v:>4}{mark[res.sources[i][j]]}" for j, v in enumerate(row))
        print(f"  {i:>2} {labels[i]:<4}"[:8].ljust(7) + cells)
    print("  (분 · 공백=API  c=캐시  *=Haversine 폴백  ~=같은 격자 추정)")


async def run(args) -> None:
    api_key = api_key_from_env()
    trip = build_trip()
    if api_key and not args.no_geocode:
        await geocode_trip(trip, api_key)

    cfg = AdapterConfig(mode=Mode(args.mode), cache_precision=args.precision)
    cache = RedisCache(args.redis, cfg.cache_ttl_seconds) if args.redis else MemoryLRUCache(ttl_seconds=cfg.cache_ttl_seconds)

    async with KakaoTimeMatrixProvider(api_key, cfg, cache) as provider:
        result = None
        for r in range(1, args.runs + 1):
            result = await build_real_time_matrix(trip, provider=provider)
            s = result.stats
            print(f"[run {r}] {result.elapsed_ms:7.1f} ms | 쌍 {s.get('pairs', 0)} · 고유키 {s.get('unique_keys', 0)} "
                  f"· HTTP {s.get('http_calls', 0)} (에러 {s.get('http_errors', 0)}) "
                  f"· api {s.get('api', 0)} · cache {s.get('cache', 0)} "
                  f"· fallback {s.get('fallback', 0)} · near {s.get('near', 0)}")

        size = f" · 저장 {len(cache)}키" if hasattr(cache, "__len__") else ""
        print(f"[cache] {type(cache).__name__} · 정밀도 소수점 {cfg.cache_precision}자리 "
              f"· TTL {cfg.cache_ttl_seconds // 3600}h{size}")

    print()
    print_matrix(trip, result)

    # ── 핵심: 엔진은 수정 없이 tt만 주입 ──
    M = build_time_matrix(trip, tt=result.as_travel_time_fn())
    sol = solve(trip, M)
    print("\n=== 실측 매트릭스 기반 코스 ===")
    print(render(trip, sol, M))

    # 비교용: 기존 Haversine 추정 코스
    M0 = build_time_matrix(trip, tt=estimate_walk_minutes)
    sol0 = solve(trip, M0)
    same = "동일" if sol0.order == sol.order else "다름"
    print(f"\n[비교] Haversine 추정 코스: 방문 {len(sol0.order)}곳 · 이동 {sol0.travel}분 · 종료 "
          f"{sol0.finish // 60:02d}:{sol0.finish % 60:02d}  → 순서 {same}")


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=[m.value for m in Mode], default="walk")
    ap.add_argument("--precision", type=int, choices=[3, 4], default=4)
    ap.add_argument("--runs", type=int, default=2, help="같은 provider로 반복 호출해 캐시 효과 확인")
    ap.add_argument("--redis", default=None, help="redis://host:port/db (없으면 메모리 LRU)")
    ap.add_argument("--no-geocode", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING,
                        format="%(levelname)s %(name)s: %(message)s")
    asyncio.run(run(args))


if __name__ == "__main__":
    main()
