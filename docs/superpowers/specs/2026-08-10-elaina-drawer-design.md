# 서랍(메모) — 설계

- 날짜: 2026-08-10
- 대상 앱: `day8/index.html` (해외송금 대시보드, 단일 파일)
- DB: Supabase `llbpdejavfndqcyfbylg` · `edu` 스키마 · `elaina_` 접두사
- 관리자: `elaina@pinkage.co.kr` (JWT 이메일로 판정)

## 목적

팀의 판단을 데이터로 남긴다. 숫자 옆에 "왜 이렇게 됐는지"를 붙여 두는 자리다.
화면에서 지운 것처럼 보여도 기록은 사라지지 않는다.

## 정한 것 (2026-08-10 사용자 확정)

| 갈림길 | 결정 | 이유 |
|---|---|---|
| @멘션 대상 | 뷰어 명단 표를 따로 둔다 | 계정 18개의 이메일을 아무에게나 내보내지 않는다 |
| 본문 수정 | 불가. 지우기(소프트)만 | 기록의 무게를 지킨다. 트리거 방어선이 단순해진다 |
| 서랍 위치 | `월별 상세 내역` 표 하나 | 요청 그대로. 부품은 대상 id 를 받게 만들어 재사용 가능 |
| 다크 모드 | 라이트 전용 유지 | 앱에 다크 토큰이 없다. 서랍만 다크면 어긋난다 |

## 표 5개 — `edu` 스키마

대상은 `(target_type, target_id)` 두 값으로만 구분한다.
`target_type` 에 CHECK 를 걸지 않는다 — 걸면 새 대상을 붙일 때마다
마이그레이션이 필요해져 "부품 하나로 여러 곳에" 와 어긋난다.

### `elaina_viewers`
이 화면을 볼 수 있는 사람 = @로 부를 수 있는 사람.

| 열 | 타입 | 비고 |
|---|---|---|
| `user_id` | uuid PK | → `auth.users(id)` |
| `email` | text unique | |
| `display_name` | text unique | 본문에 `@이름` 으로 들어간다. 공백·`@` 불가 |
| `added_by` | uuid | |
| `created_at` | timestamptz | |

### `elaina_memos`

| 열 | 타입 | 비고 |
|---|---|---|
| `id` | bigint identity PK | |
| `target_type` | text | 예: `table` |
| `target_id` | text | 예: `monthly` |
| `target_label` | text | 사람이 읽는 대상 이름 |
| `body` | text | 1~4000자 |
| `author_id` | uuid | 트리거가 채운다. 이후 변경 불가 |
| `author_email` | text | 트리거가 채운다 |
| `created_at` | timestamptz | 트리거가 채운다. 이후 변경 불가 |
| `mention_ids` | uuid[] | 트리거가 본문에서 계산한다 |
| `deleted_at` / `deleted_by` | | 소프트 삭제 |

### `elaina_memo_replies`
`memo_id` 로 메모에 딸린다. 나머지는 메모와 같은 규칙.

### `elaina_mentions`
누가 누구를 불렀나. 트리거만 넣는다. `memo_id` 또는 `reply_id` 중 하나만 채워진다.

### `elaina_notifications`
`recipient_id`, `actor_id`, `actor_name`, `kind`(`mention`|`reply`),
`memo_id`, `reply_id`, `target_*`, `excerpt`, `read_at`.
메모가 지워져도 알림만 보고 무슨 일이었는지 알 수 있도록 값으로 저장한다.

## 방어선 — 화면이 아니라 DB에서 막는다

1. **anon 0** — 5개 표 모두 `revoke all from anon, public`. `authenticated` 에만 필요한 만큼만.
2. **DELETE 권한을 아무에게도 주지 않는다** — 하드 삭제가 문법적으로 불가능하다.
   지우기는 `deleted_at` 을 채우는 UPDATE 뿐이다.
3. **작성자·작성시각** — BEFORE 트리거가 `auth.uid()` / `now()` 로 덮어쓴다.
   사람이 보낸 값은 버린다.
4. **본문 수정 불가** — UPDATE 시 트리거가 `body` 를 옛 값으로 되돌린다.
   허용되는 변경은 '삭제 표시' 하나뿐이다.
5. **삭제 권한** — 본인 또는 관리자.
6. **멘션·알림** — INSERT 정책도 권한도 없다. `SECURITY DEFINER` 트리거만 넣을 수 있다.
7. **명단 표** — 표 자체는 아무에게도 열지 않는다. 이름은 `elaina_mention_list()` 로만 나간다.

### 글자와 번호를 나눈다
본문에는 `@엘라이나` 라는 이름만 들어간다. 누구를 불렀는지는 트리거가
`elaina_viewers` 명단과 대조해 `mention_ids` 에 uuid 로 따로 적는다.
클라이언트가 보낸 값은 무시하고 서버가 다시 계산하므로 남의 이름으로
부르거나 알림을 위조할 수 없다.

## 함수

| 이름 | 종류 | 하는 일 |
|---|---|---|
| `elaina_is_admin()` | invoker | JWT 이메일이 관리자인가 |
| `elaina_can_view(uuid)` | **definer** | 명단에 있는가. 정책이 자기 자신을 부르는 재귀를 피하려면 definer 라야 한다 |
| `elaina_called_ids(text)` | definer | 본문에서 부른 사람의 uuid 목록 |
| `elaina_stamp()` | invoker 트리거 | 작성자·작성시각 고정, 본문 되돌리기, 삭제 표시만 허용 |
| `elaina_fanout()` | definer 트리거 | 멘션 기록 + 알림 생성 |
| `elaina_notification_guard()` | invoker 트리거 | `read_at` 외 전부 되돌린다 |
| `elaina_mention_list()` | definer | @ 자동완성용 이름 목록 (명단에 있는 사람에게만) |
| `elaina_memo_counts(text, text[])` | invoker | 배지 건수. RLS 가 그대로 적용된다 |
| `elaina_set_viewer(text, text)` | definer | 관리자만. 명단 추가·이름 변경 |
| `elaina_remove_viewer(uuid)` | definer | 관리자만. 관리자 자신은 뺄 수 없다 |

## 화면 — 부품 하나

```js
Drawer.attach(buttonEl, { type: 'table', id: 'monthly', label: '월별 상세 내역' });
```

버튼과 대상만 넘기면 배지 갱신·팝업 열기가 붙는다. 팝업 DOM 은 한 번만 만들고
재사용한다. 나중에 월 행에 달려면 `Drawer.attach` 를 한 줄 더 부르면 된다.

- **버튼** — `월별 상세 내역` `<h2>` 오른쪽. `🗄 서랍` + 기존 `.badge` 로 건수
- **팝업** — 네이티브 `<dialog>` + `showModal()`.
  포커스 가둠·Esc 닫기가 브라우저 기본으로 따라온다. 인라인 접기는 없다
- **2단** — 왼쪽 메모 목록(+ 입력칸), 오른쪽 고른 메모의 답글.
  860px 아래에서는 위아래로 쌓인다
- **토큰** — `--r-modal` · `--card` · `--navy` · `--blush` · `--line` · `--shadow` ·
  포커스 링 `--pink`. 새 색은 만들지 않는다

### 넣지 않는 것
알림 표는 만들지만 **벨 UI 는 넣지 않는다.** 메모를 남긴 직후
`→ 데이지님에게 알림이 갔습니다` 한 줄만 보여준다. 요청받은 화면 사양
(버튼·배지·2단 팝업)에 없는 것을 임의로 늘리지 않는다. 표는 이미 벨을
얹을 수 있는 구조다.

## 명단 초기값

활성 계정 18개를 전부 넣는다. 표시 이름은 이메일 앞부분이며 현재 충돌이 없다.
교육용 공용 프로젝트라 아무도 잠기지 않게 하기 위해서다.
관리자는 `elaina_remove_viewer()` 로 언제든 뺄 수 있다.

## 검증 (적용 직후 수행)

1. 표 5개 존재 — `pg_tables`
2. RLS 켜짐 — `rowsecurity = true` 5/5
3. **anon 권한 0건** — `information_schema.role_table_grants where grantee = 'anon'`
4. DELETE 권한 0건 — 하드 삭제 불가 확인
5. 정책 목록 — 어느 역할에 무엇이 열렸는지

## 관련

- 마이그레이션 적용 방식은 [[supabase-migration-workflow]] 를 따른다
  (마이그레이션으로 작성 → MCP 로 직접 적용 → 표·RLS·anon 0 검증)
