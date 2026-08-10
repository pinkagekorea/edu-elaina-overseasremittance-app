-- 스키마 기본 권한으로 딸려온 DELETE/TRUNCATE 를 표 단위로 회수한다.
-- 정책이 없어 어차피 막히지만, 권한 자체를 없애 두는 편이 방어선이 하나 더 앞선다.
revoke delete, truncate, references, trigger on edu.hani_memos        from authenticated;
revoke delete, truncate, references, trigger on edu.hani_memo_replies from authenticated;
revoke all on edu.hani_memos        from anon;
revoke all on edu.hani_memo_replies from anon;