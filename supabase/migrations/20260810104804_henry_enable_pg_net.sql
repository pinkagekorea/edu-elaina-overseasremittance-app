-- 슬랙 알림용. pg_net 은 비동기라 HTTP 호출이 트랜잭션을 붙잡지 않는다.
-- 큐 적재는 트랜잭션 안에서 일어나므로, 메모 저장이 롤백되면 슬랙도 안 나간다.
create extension if not exists pg_net;
