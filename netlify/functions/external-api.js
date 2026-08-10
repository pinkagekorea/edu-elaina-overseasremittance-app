// ------------------------------------------------------------------
// 외부 API 를 부를 자리 (Netlify Function)
//
// 이 파일은 Netlify 서버에서만 실행된다. 브라우저로 내려가지 않는다.
// 열쇠는 이 파일에 절대 적지 않는다 — 환경변수에서만 읽는다.
// ------------------------------------------------------------------

// 환경변수 이름만 코드에 적는다. 값은 적지 않는다.
var KEY_NAME = 'EXTERNAL_API_KEY';

exports.handler = async function (event) {
  var headers = {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store'
  };

  function reply(payload) {
    // 열쇠가 없든 있든, 오류가 나든 항상 200 으로 돌려준다.
    // 화면이 에러로 죽지 않고 사유를 그대로 보여줄 수 있게.
    return { statusCode: 200, headers: headers, body: JSON.stringify(payload, null, 2) };
  }

  var key = String(process.env[KEY_NAME] || '').trim();

  // ── 아직 열쇠가 없을 때 ───────────────────────────────────────
  if (!key) {
    return reply({
      ok: false,
      configured: false,
      message: '열쇠가 아직 설정되지 않았습니다',
      keyName: KEY_NAME,
      hint: 'Netlify → Site configuration → Environment variables 에 '
          + KEY_NAME + ' 를 추가한 뒤 다시 배포하세요.'
    });
  }

  // ── 열쇠가 있을 때 ───────────────────────────────────────────
  try {
    // 여기가 나중에 외부 API 를 부를 자리입니다.
    //
    //   var r = await fetch('https://api.example.com/v1/thing', {
    //     headers: { Authorization: 'Bearer ' + key }
    //   });
    //   var data = await r.json();
    //   return reply({ ok: true, configured: true, data: data });
    //
    // 주의: key 값이나 그 일부(앞 몇 글자, 길이 등)를 응답에 담지 마세요.
    //       응답은 그대로 브라우저까지 내려갑니다.

    return reply({
      ok: true,
      configured: true,
      message: '열쇠가 설정되어 있습니다. 아직 외부 API 를 부르지는 않습니다.',
      keyName: KEY_NAME
    });
  } catch (err) {
    return reply({
      ok: false,
      configured: true,
      message: '외부 API 를 부르는 중 오류가 발생했습니다',
      error: String(err && err.message ? err.message : err)
    });
  }
};
