/* ==================================================================
   서비스워커 — 폰이 이 앱을 기억하는 방식

   ★ 다시 배포할 때 할 일은 하나뿐이다: 아래 VERSION 숫자를 올린다.
     숫자가 바뀌면 캐시 이름이 바뀌고, 새 워커가 켜질 때 이름이 다른
     옛 캐시를 전부 지운다. 그래서 폰에 옛 화면이 남지 않는다.

   규칙
     1) HTML(화면)은 언제나 네트워크가 먼저. 받아오면 그것을 보여주고
        사본만 남긴다. 네트워크가 죽었을 때만 사본을 꺼낸다.
        → 배포하면 새로고침 한 번으로 바로 새 화면이 된다.
     2) 아이콘·manifest·CDN 글꼴·라이브러리는 캐시가 먼저 (빠르고,
        비행기 모드에서도 화면이 뜬다). 갱신은 VERSION 을 올릴 때.
     3) 로그인·데이터·서버 함수는 담지 않는다. 캐시에서 내주면
        옛 숫자나 남의 데이터를 보여줄 수 있다. 손대지 않고 통과시킨다.
     4) 새 버전은 대기하지 않는다 (skipWaiting + clients.claim).
   ================================================================== */

const VERSION = 'v11';                    // ← 배포할 때마다 이 숫자만 올린다
const CACHE   = 'day8-' + VERSION;

/* 오프라인에서도 화면이 뜨도록 미리 담아 두는 껍데기 (모두 같은 출처) */
const SHELL = [
  './',
  './manifest.webmanifest',
  './icon-192.png',
  './icon-512.png',
  './icon-maskable-512.png',
  './apple-touch-icon.png'
];

/* 캐시에 담아도 되는 남의 집 — 판올림 주소가 박혀 있는 것들만 */
const RUNTIME_HOSTS = ['cdn.jsdelivr.net', 'unpkg.com'];

/* 담아도 되는 요청인가. 여기서 false 면 서비스워커는 아예 끼어들지 않는다.
   (supabase.co · 구글 로그인 · 서명 URL 은 여기에 걸려 그대로 통과한다) */
function cacheable(url, sameOrigin) {
  if (sameOrigin) {
    return !url.pathname.startsWith('/.netlify/functions/');   // 서버 함수 응답은 담지 않는다
  }
  return RUNTIME_HOSTS.indexOf(url.hostname) !== -1;
}

/* 네트워크도 사본도 없을 때 내보내는 마지막 화면 — 앱과 같은 색·서체 */
const OFFLINE_PAGE = `<!doctype html>
<html lang="ko"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>해외송금 현황 — 연결 없음</title>
<style>
  body { margin:0; min-height:100dvh; display:flex; align-items:center; justify-content:center;
         padding: max(20px, env(safe-area-inset-top)) 20px max(20px, env(safe-area-inset-bottom));
         background:#FDFCF8; color:#555; font-size:14px; line-height:1.6;
         font-family: Pretendard, system-ui, -apple-system, 'Segoe UI', sans-serif; }
  .box { background:#fff; border:1px solid #c9c9c9; border-radius:14px; padding:20px; max-width:360px; }
  h1 { font-size:17px; font-weight:700; color:#1C3160; margin:0 0 8px; }
  p { margin:0 0 14px; }
  button { font:inherit; font-weight:700; font-size:16px; min-height:44px; width:100%;
           background:#1C3160; color:#fff; border:1px solid #1C3160; border-radius:10px; cursor:pointer; }
</style></head>
<body><div class="box">
  <h1>연결이 없어 화면을 받지 못했습니다</h1>
  <p>이 앱은 숫자를 서버에서 받아 그리기 때문에, 연결이 없으면 표와 차트를 보여줄 수 없습니다.
     연결을 확인한 뒤 다시 시도해 주세요.</p>
  <button type="button" onclick="location.reload()">다시 시도</button>
</div></body></html>`;

function offlineResponse() {
  return new Response(OFFLINE_PAGE, {
    status: 503,
    headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }
  });
}

/* ---- 설치: 껍데기를 담고, 기다리지 않는다 ------------------------ */
self.addEventListener('install', function (e) {
  e.waitUntil((async function () {
    const cache = await caches.open(CACHE);
    /* allSettled — 파일 하나가 없어도 설치 자체는 끝낸다.
       (설치가 실패하면 옛 워커가 계속 살아 옛 화면을 내준다) */
    await Promise.allSettled(
      SHELL.map(function (u) { return cache.add(new Request(u, { cache: 'reload' })); })
    );
    await self.skipWaiting();
  })());
});

/* ---- 켜짐: 옛 캐시를 버리고, 열린 화면까지 곧바로 맡는다 --------- */
self.addEventListener('activate', function (e) {
  e.waitUntil((async function () {
    const names = await caches.keys();
    await Promise.all(
      names.filter(function (n) { return n !== CACHE; })
           .map(function (n) { return caches.delete(n); })
    );
    await self.clients.claim();
  })());
});

/* ---- 요청 가로채기 ---------------------------------------------- */
self.addEventListener('fetch', function (e) {
  const req = e.request;
  if (req.method !== 'GET') return;                       // 쓰기는 건드리지 않는다

  const url = new URL(req.url);
  const sameOrigin = (url.origin === self.location.origin);
  if (!cacheable(url, sameOrigin)) return;                // 데이터·함수·로그인은 통과

  const wantsHtml = req.mode === 'navigate' ||
                    (req.headers.get('accept') || '').indexOf('text/html') !== -1;

  e.respondWith(wantsHtml ? htmlNetworkFirst(req) : assetCacheFirst(req));
});

/* 화면 = 네트워크 우선. 사본은 항상 './' 한 자리에만 남긴다
   (?drawer=1 같은 주소로 들어와도 돌려주는 HTML 은 같은 파일이다) */
async function htmlNetworkFirst(req) {
  const cache = await caches.open(CACHE);
  try {
    const fresh = await fetch(req);
    /* redirected 사본은 담지 않는다 — 나중에 그것을 화면 이동에 내주면
       브라우저가 거부해서 오프라인 화면이 통째로 깨진다 */
    if (fresh && fresh.ok && !fresh.redirected) cache.put('./', fresh.clone());
    return fresh;                                          // 서버가 답했으면 그 답을 그대로
  } catch (err) {
    const hit = (await cache.match(req, { ignoreSearch: true })) || (await cache.match('./'));
    return hit || offlineResponse();
  }
}

/* 그 밖 = 캐시 우선. 없으면 받아서 담는다 */
async function assetCacheFirst(req) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(req);
  if (hit) return hit;
  try {
    const res = await fetch(req);
    /* opaque(다른 출처의 CORS 없는 응답)는 ok 가 false 라서 따로 챈다 */
    if (res && (res.ok || res.type === 'opaque')) cache.put(req, res.clone());
    return res;
  } catch (err) {
    return Response.error();
  }
}
