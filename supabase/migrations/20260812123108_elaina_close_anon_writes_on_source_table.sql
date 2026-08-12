-- ═══════════════════════════════════════════════════════════════
-- 원본 표 — anon 의 쓰기를 닫는다
--
--   공개키(publishable key)는 브라우저에 그대로 내려간다. 그것만 있으면
--   로그인 없이 anon 으로 붙을 수 있다. 그 anon 에게 INSERT·UPDATE·DELETE
--   권한이 있었고, 정책 셋이 전부 `using (true)` 였다 —
--   즉 누구나 원본 숫자를 지우거나 바꿀 수 있는 상태였다.
--
--   읽기(authenticated + @pinkage.co.kr)는 건드리지 않는다.
--   화면이 쓰는 곳은 관리자 삭제 하나뿐이고 그것은 로그인 상태(authenticated)다.
--
--   권한과 정책을 둘 다 없앤다. 권한만 지워도 막히지만(RLS 판정 전에
--   Postgres 가 막는다), `using (true)` 정책이 남아 있으면 나중에 누가
--   권한을 다시 주는 순간 문이 그대로 열린다.
-- ═══════════════════════════════════════════════════════════════

revoke insert, update, delete on edu.edu_elaina_overseasremittance from anon;

drop policy if exists "anon can insert" on edu.edu_elaina_overseasremittance;
drop policy if exists "anon can update" on edu.edu_elaina_overseasremittance;
drop policy if exists "anon can delete" on edu.edu_elaina_overseasremittance;

notify pgrst, 'reload schema';
