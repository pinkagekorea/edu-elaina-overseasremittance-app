# 수정요청 (elaina) — 설계

작성 2026-08-11 · 적용 완료

## 왜

"이거 고쳐 주세요" 가 카톡·말·복도에서 흩어진다. 어느 화면 이야기인지 되묻고,
누가 뭘 요청했는지 추적이 안 되고, 처리 여부를 서로 모른다. 앱 안에서 바로
접수해 한곳에 쌓고, 상태를 붙여 눈에 보이게 한다.

## 무엇을 만들었나

| 조각 | 위치 |
|---|---|
| 표 `edu.elaina_fix_requests` | `20260811084251_elaina_fix_requests_table_and_rls.sql` |
| 서버함수 3개 | `20260811084340_elaina_fix_requests_functions.sql` |
| 슬랙 기록 연결 컬럼 | `20260811084352_elaina_slack_deliveries_fix_request_id.sql` |
| 떠 있는 버튼 + 팝업 (`Fix` 모듈) | `index.html` |
| 슬랙 heads-up 분기 | `supabase/functions/elaina-slack-relay/index.ts` |

## 정한 것과 그 이유

**슬랙은 Edge Function 을 재사용한다.** 처음 요구는 "9일차 `_slack_notify` 재사용"
이었으나 그런 DB 함수는 없다. DB 트리거로 슬랙을 쏘는 것은 다른 수강생
(`henry_slack_heads_up`, `hani_slack_headsup`) 방식이고, 이 앱은
`elaina_slack_plumbing` 첫 주석에서 *비밀값은 DB 에도 코드에도 두지 않고 Edge
환경변수에만 둔다* 고 못 박아 두었다. 그 원칙을 깨지 않기 위해 기존
`elaina-slack-relay` 에 `fix_request_id` 분기를 더했다. 그 함수는 이미 "번호만
받고 본문은 DB 에서 다시 읽는" 구조라 위조 방지가 그대로 따라온다.

**수정요청은 채널로만 보낸다.** 특정 개인이 아니라 팀에게 가는 알림이라
개인 DM(`dm` 등급)은 시도하지 않는다.

**떠 있는 버튼은 원형이 아니라 글자 있는 둥근 사각형이다.** 원형은 이 문서의
반경 4단계(`--r-badge/control/card/modal`) 밖이고, 아이콘만으로는 뜻이 전해지지
않는다.

**팝업은 서랍(`.drawer`)의 부품을 그대로 입는다.** 새 색·새 반경·새 서체가 없다.
다만 새 요청 폼을 위로, 목록을 아래로 뒤집었다 — 이 팝업은 읽기보다 쓰기가
먼저다.

**화면 출처는 사용자가 적지 않는다.** 팝업을 띄우기 *전에* 잡는다
(띄운 뒤에는 이 팝업이 "열린 팝업" 이 되어 버린다). 순서는
① 열려 있는 팝업 제목 → ② 화면에 걸친 섹션의 `h2` → ③ `document.title`.
`viewport`(390x844)까지 넣은 이유는 레이아웃 관련 요청이 이 값 없이는 재현이
안 되기 때문이다. 폼에 *"〈월별 상세 내역〉 화면에서 접수됩니다"* 로 보여줘
사용자가 무엇이 함께 저장되는지 알 수 있게 했다.

## 잠금

- `authenticated` 에 **select·insert 만** 준다. update/delete 권한이 없으므로
  상태 변경·삭제는 RLS 판정 전에 Postgres 가 막는다. 정책으로 막는 것보다 강하다.
- 정책 둘: 읽기 `author_id = auth.uid() or elaina_is_admin()`,
  쓰기 `author_id = auth.uid() and elaina_can_view(auth.uid())`.
- 트리거 `elaina_fix_stamp` 가 작성자·이메일·시각·처음 상태(`open`)를 찍는다.
  UPDATE 때는 본문·작성자·화면정보를 되돌리고, 상태를 건드리면
  `elaina_is_admin()` 을 다시 확인한다 — SECURITY DEFINER 함수 안에서도
  `auth.jwt()` 는 그 요청의 것이라 이 검사가 산다.
- 캡처는 기존 `elaina_check_images` 를 재사용한다 — 본인이 방금 올린 것만,
  10장까지, `elaina-memo` 비공개 버킷.
- `anon` 은 표·함수 전부 권한 0.

## 검증 (적용 후 실측)

메타데이터: 표 존재 · RLS true · 정책 2개 · `authenticated` = INSERT,SELECT
(update/delete false) · `anon` 표 권한 0건 · `anon` 함수 실행권한 전부 false ·
트리거 함수는 `authenticated` 도 실행 불가.

동작(사용자로 위장해 12건, 마지막에 관리자 삭제 함수로 흔적 제거):
남의 이름으로 남기려 해도 본인으로 기록됨 · `status`를 `done`으로 보내도 `open`
강제 · 남의 요청 0건 보임 · 직접 UPDATE 거부(42501) · 상태변경·삭제 함수 거부
(42501) · 관리자는 전부 보이고 상태·메모·담당자 기록됨 · 없는 상태값 거부
(22023) · 관리자 삭제 성공.

## 일부러 안 한 것

상태가 바뀔 때 요청자에게 알림(목록에서 보면 된다) · 요청별 답글 스레드(서랍이
그 역할) · 소프트 삭제와 비석(반려 상태가 그 역할) · 기기명·UA 수집.

## 알려진 한계

- 서랍·캡처 팝업이 열려 있는 동안에는 떠 있는 버튼을 누를 수 없다. 모달
  `<dialog>` 가 위 레이어를 차지해 아래가 비활성이 되기 때문이다. 그 화면에서
  요청하려면 팝업을 닫아야 한다. (필요해지면 서랍 머리에 버튼을 하나 더 단다.)
- `elaina_is_admin()` 은 이메일 하나로 못 박혀 있다. 관리자를 늘리려면
  마이그레이션이 필요하다.
- 슬랙은 웹훅(`ELAINA_SLACK_WEBHOOK_URL`)이 있을 때만 실제로 나간다. 없으면
  등급 `bell` 로 기록만 남는다. 어느 쪽이든 요청 저장은 이미 끝난 상태다.
