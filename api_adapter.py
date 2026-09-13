"""
api_adapter.py — 카카오맵 길찾기 REST API 기반 N×N 이동시간 매트릭스 어댑터
---------------------------------------------------------------------
whim_route_engine.build_time_matrix(trip, tt=...)의 `tt` 자리에 주입할 이동시간 함수를
'실제 경로 API' 데이터로 만들어 준다. 엔진 코드는 건드리지 않는다.

  사용 흐름
    async with KakaoTimeMatrixProvider(api_key) as provider:
        result = await build_real_time_matrix(trip, provider=provider)   # 비동기 N×N 선조회
    M = build_time_matrix(trip, tt=result.as_travel_time_fn())            # 엔진 쪽 DI
    sol = solve(trip, M)

  사용 API (Kakao Developers > 카카오맵 REST API, 2026-07 오픈)
    도보      GET https://dapi.kakao.com/v2/routing/walk           → route.properties.totalTime (초)
    대중교통  GET https://dapi.kakao.com/v2/routing/publictraffic  → routes[].properties.totalTime (초)
    공통 파라미터 start_x, start_y, end_x, end_y  (x=경도, y=위도, WGS84)
    인증 헤더  Authorization: KakaoAK {REST_API_KEY}

  4중 방어
    1) 캐시(LRU/Redis)  2) 요청 중복 제거(dedup)  3) 로컬 일일 쿼터 + 서킷 브레이커
    4) 셀 단위 Haversine 폴백 + 매트릭스 전체 데드라인 → 어떤 장애에도 매트릭스는 반드시 채워진다.
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import os
import time
from collections import Counter, OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Callable, Dict, List, Optional, Protocol, Sequence, Tuple, Union

import aiohttp

from whim_route_engine import Trip, estimate_walk_minutes, haversine_km

log = logging.getLogger("whim.api_adapter")

Coord = Tuple[float, float]                              # (lat, lon)
TravelTimeFn = Callable[[float, float, float, float], int]

KAKAO_BASE_URL = "https://dapi.kakao.com"
PATHS = {"walk": "/v2/routing/walk", "transit": "/v2/routing/publictraffic"}
KST = timezone(timedelta(hours=9))


class Mode(str, Enum):
    WALK = "walk"
    TRANSIT = "transit"   # 결과 없음(너무 가까움 등)이면 도보 API로 재조회
    BEST = "best"         # 가까우면 도보만, 멀면 도보·대중교통 동시 조회 후 짧은 쪽


@dataclass
class AdapterConfig:
    mode: Mode = Mode.WALK
    cache_precision: int = 4            # 4 ≈ 11m 격자, 3 ≈ 110m 격자
    cache_ttl_seconds: int = 6 * 3600
    walk_symmetric: bool = True         # 도보는 A→B ≈ B→A → 72쌍을 36회 호출로
    max_concurrency: int = 8            # 동시 HTTP 요청 상한 (카카오 초당 제한 보호)
    request_timeout_s: float = 3.0      # 요청 1건 타임아웃
    matrix_deadline_s: float = 8.0      # 매트릭스 전체 예산. 넘으면 남은 셀은 폴백
    max_retries: int = 0                # 기본 0 = 실패 즉시 폴백. 5xx/타임아웃에만 적용
    retry_backoff_s: float = 0.3
    daily_quota: int = 1000             # API(도보/대중교통)별 로컬 일일 한도 (KST 자정 리셋)
    best_walk_only_km: float = 1.0      # BEST 모드에서 이 직선거리 미만이면 도보만 조회
    breaker_threshold: int = 3          # 연속 실패 N회 → 서킷 오픈
    breaker_cooldown_s: float = 30.0
    base_url: str = KAKAO_BASE_URL


# ─────────────────────────────────────────────────────────────
# 1. 캐시 레이어 — 인터페이스만 맞추면 LRU / Redis 교체 가능
# ─────────────────────────────────────────────────────────────

class CacheBackend(Protocol):
    async def get(self, key: str) -> Optional[int]: ...
    async def set(self, key: str, minutes: int) -> None: ...
    async def close(self) -> None: ...


class MemoryLRUCache:
    """단일 프로세스용 LRU + TTL. asyncio 단일 스레드에서만 접근하므로 락 불필요."""

    def __init__(self, maxsize: int = 50_000, ttl_seconds: int = 6 * 3600):
        self.maxsize, self.ttl = maxsize, ttl_seconds
        self._d: "OrderedDict[str, Tuple[float, int]]" = OrderedDict()

    async def get(self, key: str) -> Optional[int]:
        item = self._d.get(key)
        if item is None:
            return None
        expires, minutes = item
        if expires < time.monotonic():
            del self._d[key]
            return None
        self._d.move_to_end(key)
        return minutes

    async def set(self, key: str, minutes: int) -> None:
        self._d[key] = (time.monotonic() + self.ttl, minutes)
        self._d.move_to_end(key)
        while len(self._d) > self.maxsize:
            self._d.popitem(last=False)

    async def close(self) -> None:
        pass

    def __len__(self) -> int:
        return len(self._d)


class RedisCache:
    """다중 인스턴스 공유 캐시. `pip install redis` 필요. Redis 장애도 캐시 미스로만 취급한다."""

    def __init__(self, url: str, ttl_seconds: int = 6 * 3600, prefix: str = "whim:tt:"):
        import redis.asyncio as redis   # 선택 의존성 — 쓸 때만 import
        self._r = redis.from_url(url, decode_responses=True,
                                 socket_timeout=0.5, socket_connect_timeout=0.5)
        self.ttl, self.prefix = ttl_seconds, prefix

    async def get(self, key: str) -> Optional[int]:
        try:
            v = await self._r.get(self.prefix + key)
            return int(v) if v is not None else None
        except Exception as e:
            log.warning("redis get 실패 → 캐시 미스 처리: %r", e)
            return None

    async def set(self, key: str, minutes: int) -> None:
        try:
            await self._r.set(self.prefix + key, minutes, ex=self.ttl)
        except Exception as e:
            log.warning("redis set 실패 → 무시: %r", e)

    async def close(self) -> None:
        closer = getattr(self._r, "aclose", None) or self._r.close
        try:
            await closer()
        except Exception:
            pass


def _q(x: float, precision: int) -> str:
    return f"{round(x, precision):.{precision}f}"


def cache_key(mode: str, a: Coord, b: Coord, precision: int, symmetric: bool) -> str:
    """'walk:36.6390,127.4895>36.6371,127.4881'. symmetric이면 두 끝점을 정렬해 A→B/B→A가 키를 공유."""
    sa = f"{_q(a[0], precision)},{_q(a[1], precision)}"
    sb = f"{_q(b[0], precision)},{_q(b[1], precision)}"
    if symmetric and sb < sa:
        sa, sb = sb, sa
    return f"{mode}:{sa}>{sb}"


# ─────────────────────────────────────────────────────────────
# 2. 장애 방어 부품 — 일일 쿼터, 서킷 브레이커
# ─────────────────────────────────────────────────────────────

class ApiUnavailable(Exception):
    """네트워크/타임아웃/한도초과/서버오류 — 폴백 대상."""


class NoRoute(Exception):
    """정상 응답이지만 경로가 없음(SAME_POINT, NO_RESULTS 등) — 장애로 세지 않는다."""


class DailyQuota:
    """카카오 서버에서 429를 맞기 전에 로컬에서 먼저 차단. 프로세스 메모리 기준(멀티 인스턴스면 Redis INCR로 교체)."""

    def __init__(self, limit: int):
        self.limit = limit
        self._day = datetime.now(KST).date()
        self.used = 0

    def try_acquire(self) -> bool:
        today = datetime.now(KST).date()
        if today != self._day:
            self._day, self.used = today, 0
        if self.used >= self.limit:
            return False
        self.used += 1
        return True

    def exhaust(self) -> None:
        """서버가 429를 주면 오늘 한도는 끝난 것으로 본다."""
        self.used = self.limit


class CircuitBreaker:
    """연속 실패 시 일정 시간 API 호출 자체를 생략 → 72개 요청이 줄줄이 타임아웃을 기다리지 않게."""

    def __init__(self, threshold: int, cooldown_s: float):
        self.threshold, self.cooldown_s = threshold, cooldown_s
        self._fails = 0
        self._open_until = 0.0

    def allow(self) -> bool:
        return time.monotonic() >= self._open_until

    def success(self) -> None:
        self._fails = 0

    def failure(self) -> None:
        self._fails += 1
        if self._fails >= self.threshold:
            self.trip(self.cooldown_s)

    def trip(self, seconds: float) -> None:
        was_closed = self.allow()
        self._fails = 0
        self._open_until = max(self._open_until, time.monotonic() + seconds)
        if was_closed:
            log.warning("서킷 오픈 %.0f초 — 이 동안 API 호출 없이 폴백", seconds)


# ─────────────────────────────────────────────────────────────
# 3. 카카오 HTTP 클라이언트 — 요청 1건 = 좌표쌍 1개
# ─────────────────────────────────────────────────────────────

async def kakao_error_detail(resp: aiohttp.ClientResponse) -> str:
    """카카오 에러 응답 본문을 사람이 읽을 원인 문자열로 변환. 이 함수 자체는 절대 예외를 던지지 않는다.
    형식 예) {"errorType":"NotAuthorizedError","message":"App(whim) disabled OPEN_MAP_AND_LOCAL service."}
            {"code":-401,"msg":"wrong appKey(...) format"}"""
    try:
        text = await resp.text()
    except Exception as e:
        return f"(본문 읽기 실패: {e!r})"
    try:
        body = json.loads(text)
        if isinstance(body, dict):
            kind = body.get("errorType") or body.get("code")
            msg = body.get("message") or body.get("msg")
            if kind is not None or msg:
                return f"{kind}: {msg}"
    except ValueError:
        pass
    return text.strip()[:500] or "(빈 본문)"


def _parse_seconds(kind: str, data: dict) -> int:
    status = data.get("status")
    if status != "OK":
        raise NoRoute(str(status))
    if kind == "walk":
        return int(data["route"]["properties"]["totalTime"])
    routes = data.get("routes") or []
    if not routes:
        raise NoRoute("NO_RESULTS")
    # 주의: 카카오 안내상 대중교통 결과는 첫 승차 전/마지막 하차 후 도보 구간을 포함하지 않을 수 있다.
    return min(int(r["properties"]["totalTime"]) for r in routes)


class KakaoRouteClient:
    def __init__(self, session: aiohttp.ClientSession, cfg: AdapterConfig):
        self.session, self.cfg = session, cfg
        self.sem = asyncio.Semaphore(cfg.max_concurrency)
        self.breaker = CircuitBreaker(cfg.breaker_threshold, cfg.breaker_cooldown_s)
        self.quota = {k: DailyQuota(cfg.daily_quota) for k in PATHS}
        self.http_calls = Counter()   # 누적 통계: {"walk": n, "transit": n, "error": n}

    async def seconds(self, kind: str, a: Coord, b: Coord) -> int:
        url = self.cfg.base_url + PATHS[kind]
        params = {"start_x": f"{a[1]:.7f}", "start_y": f"{a[0]:.7f}",
                  "end_x": f"{b[1]:.7f}", "end_y": f"{b[0]:.7f}"}
        last: Exception = ApiUnavailable("unknown")

        for attempt in range(self.cfg.max_retries + 1):
            try:
                async with self.sem:
                    # 세마포어 대기 중에 서킷이 열렸을 수 있으므로 '획득 후' 검사한다
                    if not self.breaker.allow():
                        raise ApiUnavailable("circuit open")
                    if not self.quota[kind].try_acquire():
                        raise ApiUnavailable(f"{kind} 로컬 일일 한도({self.cfg.daily_quota}) 소진")
                    self.http_calls[kind] += 1
                    async with self.session.get(url, params=params) as resp:
                        if resp.status == 200:
                            try:
                                secs = _parse_seconds(kind, await resp.json(content_type=None))
                            except NoRoute:
                                self.breaker.success()       # 서버는 정상
                                raise
                            except (ValueError, KeyError, TypeError) as e:
                                raise ApiUnavailable(f"응답 파싱 실패: {e!r}")
                            self.breaker.success()
                            return secs

                        self.http_calls["error"] += 1
                        if resp.status in (401, 403):
                            detail = await kakao_error_detail(resp)
                            if self.breaker.allow():         # 동시 요청이 여러 개 실패해도 ERROR는 1회만
                                log.error("카카오 %s API 인증/권한 오류 HTTP %d — %s "
                                          "(키 값 / [제품 설정 > 카카오맵] 사용 설정 확인)",
                                          kind, resp.status, detail)
                            self.breaker.trip(3600)          # 키 문제 — 재시도 무의미
                            raise ApiUnavailable(f"HTTP {resp.status} (인증/권한) {detail}")
                        if resp.status == 429:
                            self.quota[kind].exhaust()
                            self.breaker.trip(300)
                            raise ApiUnavailable("HTTP 429 (호출 한도 초과)")
                        if 400 <= resp.status < 500:
                            raise ApiUnavailable(f"HTTP {resp.status}")   # 요청 자체 문제 — 재시도 X
                        last = ApiUnavailable(f"HTTP {resp.status}")    # 5xx → 재시도 후보
            except (asyncio.TimeoutError, aiohttp.ClientError) as e:
                self.http_calls["error"] += 1
                last = ApiUnavailable(f"network: {type(e).__name__}")

            self.breaker.failure()
            if attempt < self.cfg.max_retries:
                await asyncio.sleep(self.cfg.retry_backoff_s * (2 ** attempt))
        raise last


# ─────────────────────────────────────────────────────────────
# 4. 매트릭스 빌더
# ─────────────────────────────────────────────────────────────

@dataclass
class MatrixResult:
    points: List[Coord]
    matrix: List[List[int]]                 # 분 단위, 대각선 0
    sources: List[List[str]]                # self | api | cache | near | fallback
    stats: Dict[str, int] = field(default_factory=dict)
    elapsed_ms: float = 0.0

    def as_travel_time_fn(self, fallback: TravelTimeFn = estimate_walk_minutes) -> TravelTimeFn:
        """엔진의 build_time_matrix(trip, tt=...)에 그대로 주입할 동기 함수. 조회는 O(1) dict lookup."""
        table: Dict[Tuple[float, float, float, float], int] = {}
        for i, a in enumerate(self.points):
            for j, b in enumerate(self.points):
                if i != j:
                    table[(a[0], a[1], b[0], b[1])] = self.matrix[i][j]

        def tt(a_lat: float, a_lon: float, b_lat: float, b_lon: float) -> int:
            v = table.get((a_lat, a_lon, b_lat, b_lon))
            return v if v is not None else fallback(a_lat, a_lon, b_lat, b_lon)
        return tt


class KakaoTimeMatrixProvider:
    """세션·캐시·쿼터·서킷 상태를 요청 간에 공유하는 장수 객체. 앱 기동 시 1개 만들어 재사용한다."""

    def __init__(self, api_key: Optional[str], config: Optional[AdapterConfig] = None,
                 cache: Optional[CacheBackend] = None,
                 fallback: TravelTimeFn = estimate_walk_minutes):
        self.api_key = (api_key or "").strip() or None
        self.cfg = config or AdapterConfig()
        # `cache or ...`는 금지: 빈 MemoryLRUCache는 __len__ == 0이라 False로 평가돼 주입한 캐시가 버려진다
        self.cache: CacheBackend = (cache if cache is not None
                                    else MemoryLRUCache(ttl_seconds=self.cfg.cache_ttl_seconds))
        self.fallback = fallback
        self._session: Optional[aiohttp.ClientSession] = None
        self._client: Optional[KakaoRouteClient] = None
        if not self.api_key:
            log.warning("KAKAO_REST_API_KEY 없음 → 캐시 미스는 전부 Haversine 폴백으로 계산")

    async def __aenter__(self) -> "KakaoTimeMatrixProvider":
        if self.api_key:
            self._session = aiohttp.ClientSession(
                base_url=None,
                headers={"Authorization": f"KakaoAK {self.api_key}"},
                timeout=aiohttp.ClientTimeout(total=self.cfg.request_timeout_s),
                # keep-alive 커넥션 풀 재사용: 요청마다 TLS 핸드셰이크를 반복하지 않는다
                connector=aiohttp.TCPConnector(limit=self.cfg.max_concurrency, ttl_dns_cache=300),
            )
            self._client = KakaoRouteClient(self._session, self.cfg)
        return self

    async def __aexit__(self, *exc) -> None:
        if self._session:
            await self._session.close()
        await self.cache.close()

    @property
    def client(self) -> Optional[KakaoRouteClient]:
        return self._client

    # ── 내부 ──
    def _symmetric(self) -> bool:
        return self.cfg.mode is Mode.WALK and self.cfg.walk_symmetric

    async def _cache_get(self, key: str) -> Optional[int]:
        try:
            return await self.cache.get(key)
        except Exception as e:
            log.warning("cache get 실패: %r", e)
            return None

    async def _cache_set(self, key: str, minutes: int) -> None:
        try:
            await self.cache.set(key, minutes)
        except Exception as e:
            log.warning("cache set 실패: %r", e)

    async def _query_seconds(self, a: Coord, b: Coord) -> int:
        c = self._client
        mode = self.cfg.mode
        if mode is Mode.WALK:
            return await c.seconds("walk", a, b)
        if mode is Mode.TRANSIT:
            try:
                return await c.seconds("transit", a, b)
            except NoRoute:
                return await c.seconds("walk", a, b)
        # BEST
        if haversine_km(a[0], a[1], b[0], b[1]) < self.cfg.best_walk_only_km:
            return await c.seconds("walk", a, b)
        results = await asyncio.gather(c.seconds("walk", a, b), c.seconds("transit", a, b),
                                       return_exceptions=True)
        ok = [r for r in results if isinstance(r, int)]
        if ok:
            return min(ok)
        errs = [r for r in results if isinstance(r, ApiUnavailable)]
        raise errs[0] if errs else NoRoute("walk/transit 모두 경로 없음")

    async def _resolve(self, key: str, a: Coord, b: Coord, stats: Counter) -> Optional[int]:
        """API로 분 단위 시간을 얻어 캐시에 저장. 어떤 예외도 밖으로 던지지 않는다(None = 폴백)."""
        try:
            secs = await self._query_seconds(a, b)
        except NoRoute as e:
            stats["no_route"] += 1
            log.info("경로 없음 %s: %s", key, e)
            return None
        except ApiUnavailable as e:
            stats["api_fail"] += 1
            log.info("API 실패 %s: %s", key, e)
            return None
        except Exception:
            stats["api_fail"] += 1
            log.exception("예상치 못한 오류 %s", key)
            return None
        minutes = max(1, math.ceil(secs / 60))
        await self._cache_set(key, minutes)     # 폴백값은 캐시하지 않는다 → 복구 후 실측으로 교체됨
        return minutes

    # ── 공개 ──
    async def build(self, points: Sequence[Coord]) -> MatrixResult:
        t0 = time.perf_counter()
        pts = [(float(lat), float(lon)) for lat, lon in points]
        n = len(pts)
        cfg = self.cfg
        matrix = [[0] * n for _ in range(n)]
        sources = [["self"] * n for _ in range(n)]
        stats: Counter = Counter()
        calls_before = Counter(self._client.http_calls) if self._client else Counter()

        def fill_fallback(i: int, j: int, src: str) -> None:
            matrix[i][j] = self.fallback(pts[i][0], pts[i][1], pts[j][0], pts[j][1])
            sources[i][j] = src
            stats[src] += 1

        # (1) 좌표쌍 → 캐시 키로 묶기. 같은 키는 한 번만 조회(dedup + 대칭 활용)
        groups: Dict[str, List[Tuple[int, int]]] = {}
        rep: Dict[str, Tuple[Coord, Coord]] = {}
        for i in range(n):
            for j in range(n):
                if i == j:
                    continue
                key = cache_key(cfg.mode.value, pts[i], pts[j], cfg.cache_precision, self._symmetric())
                a_cell, b_cell = key.split(":", 1)[1].split(">")
                if a_cell == b_cell:                # 같은 격자 안 → API가 SAME_POINT를 줄 거리. 추정치로 충분
                    fill_fallback(i, j, "near")
                    continue
                groups.setdefault(key, []).append((i, j))
                rep.setdefault(key, (pts[i], pts[j]))
        stats["pairs"] = n * (n - 1)
        stats["unique_keys"] = len(groups)

        def fill(key: str, minutes: int, src: str) -> None:
            for i, j in groups[key]:
                matrix[i][j] = minutes
                sources[i][j] = src
                stats[src] += 1

        # (2) 캐시 병렬 조회
        keys = list(groups)
        hits = await asyncio.gather(*(self._cache_get(k) for k in keys))
        misses = []
        for k, v in zip(keys, hits):
            if v is not None:
                fill(k, v, "cache")
            else:
                misses.append(k)

        # (3) 미스만 API 병렬 호출 — 세마포어로 동시성 제한, 전체 데드라인 적용
        if misses and self._client:
            tasks = {k: asyncio.create_task(self._resolve(k, *rep[k], stats)) for k in misses}
            done, pending = await asyncio.wait(tasks.values(), timeout=cfg.matrix_deadline_s)
            for t in pending:
                t.cancel()
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)
                stats["deadline_cut"] += len(pending)
                log.warning("매트릭스 데드라인 %.1fs 초과 → %d개 키 폴백", cfg.matrix_deadline_s, len(pending))
            for k, t in tasks.items():
                minutes = t.result() if (t in done and not t.cancelled()) else None
                if minutes is not None:
                    fill(k, minutes, "api")
                else:
                    for i, j in groups[k]:
                        fill_fallback(i, j, "fallback")
        else:
            for k in misses:
                for i, j in groups[k]:
                    fill_fallback(i, j, "fallback")

        if self._client:
            delta = Counter(self._client.http_calls)
            delta.subtract(calls_before)
            stats["http_calls"] = delta["walk"] + delta["transit"]
            stats["http_errors"] = delta["error"]
        return MatrixResult(pts, matrix, sources, dict(stats), (time.perf_counter() - t0) * 1000)


def trip_points(trip: Trip) -> List[Coord]:
    """엔진 build_time_matrix와 동일한 인덱스 규약: 0 = 출발지, 1..n = 장소."""
    return [(trip.start_lat, trip.start_lon)] + [(p.lat, p.lon) for p in trip.places]


async def build_real_time_matrix(target: Union[Trip, Sequence[Coord]],
                                 api_key: Optional[str] = None, *,
                                 provider: Optional[KakaoTimeMatrixProvider] = None,
                                 config: Optional[AdapterConfig] = None) -> MatrixResult:
    """
    N×N 실측 이동시간 매트릭스를 비동기로 구성한다. 절대 예외를 던지지 않도록 설계됨
    (최악의 경우 전 셀이 Haversine 추정치).
      - provider를 넘기면 세션/캐시/쿼터 상태를 재사용 (서버 환경 권장)
      - 안 넘기면 일회용 provider를 만들고 닫는다 (캐시도 일회용)
    """
    points = trip_points(target) if isinstance(target, Trip) else list(target)
    if provider is not None:
        return await provider.build(points)
    async with KakaoTimeMatrixProvider(api_key if api_key is not None else api_key_from_env(),
                                       config) as p:
        return await p.build(points)


def api_key_from_env(var: str = "KAKAO_REST_API_KEY") -> Optional[str]:
    """.env → 환경변수 순으로 읽는다. 키 값은 절대 로그에 남기지 않는다."""
    try:
        from dotenv import load_dotenv
        load_dotenv(override=False)
    except ImportError:
        pass
    key = (os.getenv(var) or "").strip()
    if not key or key.lower().startswith("your_"):
        return None
    return key
