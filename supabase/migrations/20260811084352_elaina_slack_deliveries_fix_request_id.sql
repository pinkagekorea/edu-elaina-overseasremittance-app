-- 수정요청도 슬랙 발송 기록을 남긴다. 같은 요청을 두 번 눌러도 두 번 가지 않게
-- Edge Function 이 이 컬럼으로 중복을 확인한다.
-- 기존 정책(actor_id = auth.uid() or elaina_is_admin()) 이 그대로 적용된다.

alter table edu.elaina_slack_deliveries
  add column if not exists fix_request_id bigint
    references edu.elaina_fix_requests(id) on delete cascade;

comment on column edu.elaina_slack_deliveries.fix_request_id is
  '수정요청 heads-up 일 때 그 요청 번호. 메모·답글 발송에서는 null 이다.';

create index if not exists elaina_slack_deliveries_fix_idx
  on edu.elaina_slack_deliveries (fix_request_id);

notify pgrst, 'reload schema';
