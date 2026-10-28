# 랩데스크

연구실 협업 공간. 프로젝트별로 작업 지시 → 결과 제출 → 확인(완료/수정요청)을 주고받고, 프로젝트마다 대화방이 하나씩 있다.

## 지금 상태: 화면 시안

`prototype/index.html` 을 브라우저로 열면 된다. 서버 없이 예시 데이터로 동작하며, 새로고침하면 처음 상태로 돌아간다.

- 계정을 골라 로그인 (교수 1명, 학생 4명)
- 홈: 내 작업(D-day 순) / 교수는 확인이 필요한 작업, 프로젝트 카드
- 프로젝트: 작업 · 대화 · 자료 탭
- 대화: 카카오톡 PC처럼 왼쪽 방 목록(프로젝트당 1개, 안 읽은 수), 오른쪽 대화 기록(날짜 구분, 검색)
- 작업 상세: 제출(파일 또는 링크, 버전 자동 증가), 완료 처리 / 수정요청, 댓글
- 알림: 화면 안 알림, 종 배지, 브라우저 알림, 프로젝트별 알림 수준
- 교수 전용 전체 현황

## 다음 단계 (실제 서비스)

Next.js + Supabase(로그인 · DB · 실시간 · 파일 저장) + PWA(홈 화면 설치, 푸시 알림).

## Supabase 준비

1. Supabase 대시보드 → **SQL Editor** → New query 에 `supabase/schema.sql` 전체를 붙여넣고 **Run**
2. **Authentication → Sign In / Providers** 에서 새 가입 허용(Allow new users to sign up)을 끄고, **Authentication → Users → Invite user** 로 연구실 사람만 초대
3. 교수 계정 지정 (SQL Editor):
   `update profiles set role = 'prof', title = '지도교수' where id = (select id from auth.users where email = '교수님 이메일');`
4. **Project Settings → API** 의 Project URL 과 anon(publishable) key 를 앱 설정에 넣는다. service_role(secret) key 는 앱에 넣지 않는다.
