-- henry-memo 버킷에 서버 측 제한을 건다.
-- 클라이언트 검사는 팻말이고 이것이 경비원이다 — API 를 직접 쳐도 여기서 막힌다.
-- 같은 프로젝트의 portal-memo 와 같은 값으로 맞춘다.
--
-- 버킷 자체는 지우지 않는다. 설정 열만 갱신한다.
update storage.buckets
set file_size_limit    = 5242880,   -- 5MB
    allowed_mime_types = array['image/png','image/jpeg','image/gif','image/webp']
where id = 'henry-memo';
