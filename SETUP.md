# 랩데스크 Supabase 연동 — 교수님이 할 일

각 단계 끝의 **확인**이 되면 다음 단계로 넘어간다.

## 1단계. 지역(Region) 확인 — 1분

Supabase 대시보드 → 프로젝트 → **Project Settings → General** (또는 Infrastructure) 에서 Region 확인.

- **Northeast Asia (Seoul)** 이면 그대로 진행
- 다른 지역이면: 아직 데이터가 없으므로 **프로젝트를 지우고 Seoul 로 새로 만드는 것**을 권장 (지역은 나중에 못 바꾼다. 앱 서버도 서울(icn1)에 둘 것이라 DB 와 맞아야 빠르다)

새로 만들 때 나오는 **Database Password** 는 메모장에 적어 프로젝트 폴더 밖에 보관. 채팅에 붙여넣지 않는다.

**확인:** Region 이 Seoul

## 2단계. DB 구조 만들기 — 2분

1. https://github.com/dgeb0508-code/forslack/blob/claude/compassionate-wozniak-zkry1w/supabase/schema.sql 열기 → 오른쪽 위 **복사 버튼**
2. Supabase 왼쪽 메뉴 **SQL Editor** → **New query** → 붙여넣기 → **Run**

**확인:**
- 아래쪽에 `Success. No rows returned`
- 왼쪽 **Table Editor** 에 표 9개: profiles, projects, project_members, tasks, task_assignees, submissions, task_comments, messages, notifications
- 왼쪽 **Storage** 에 `submissions` 버킷

오류가 나면 빨간 문구를 그대로 복사해서 보내 주세요.

## 3단계. 아무나 가입 못 하게 막기 — 1분

**Authentication → Sign In / Providers** (또는 Settings) → **Allow new users to sign up** 끄기 → Save

이후 계정은 교수님만 만든다 (앱의 멤버 관리 화면 또는 대시보드).

**확인:** 스위치가 꺼져 있음

## 4단계. 교수님 계정 만들기 — 2분

1. **Authentication → Users → Add user → Create new user**
2. 이메일, 비밀번호 입력, **Auto Confirm User** 체크 → Create
3. **SQL Editor** 에서 아래 실행 (이메일·이름만 바꿔서)

```sql
update profiles set role = 'prof', name = '김교수', title = '지도교수'
where id = (select id from auth.users where email = 'professor@univ.ac.kr');
```

**확인:** 아래를 실행하면 교수님 한 줄이 `prof` 로 나온다

```sql
select name, role, title from profiles;
```

## 5단계. 키 받기 — 2분

**Project Settings → API Keys** (Project URL 은 **Data API** 또는 프로젝트 첫 화면의 **Connect**)

| 값 | 생김새 | 어디에 |
|---|---|---|
| Project URL | `https://abcd1234.supabase.co` | 채팅으로 보내도 됨 |
| Publishable key (예전 이름 anon) | `sb_publishable_...` 또는 `eyJ...` | 채팅으로 보내도 됨 (원래 브라우저에 공개되는 값) |
| **Secret key** (예전 이름 service_role) | `sb_secret_...` 또는 `eyJ...` | **절대 채팅·스크린샷 금지.** 메모장(프로젝트 폴더 밖)에만. 6단계에서 Vercel 에 직접 넣는다 |

Secret key 는 "학생 계정 만들기·임시 비밀번호 발급" 같은 교수 전용 기능에만 서버에서 쓰인다. 노출되면 같은 화면에서 새로 발급(Roll/Revoke)하고 Vercel 값도 바꾼다.

**확인:** Project URL 과 Publishable key 를 Claude 에게 보냄 → 앱 제작 시작

---

## 6단계. 배포 (앱이 완성된 뒤 안내 예정)

1. Vercel 가입(GitHub 계정으로) → **Add New → Project → forslack 저장소 Import**
2. Environment Variables 에 3개 입력 (Import .env 로 한 번에 넣어도 됨)
   - `NEXT_PUBLIC_SUPABASE_URL` = Project URL
   - `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` = Publishable key
   - `SUPABASE_SECRET_KEY` = Secret key
3. Deploy → 나온 주소(예: `https://forslack.vercel.app`) 를 Supabase **Authentication → URL Configuration → Site URL** 에 넣기
4. 서버 지역 서울(icn1) 은 저장소의 `vercel.json` 에 미리 넣어 둔다

## 7단계. 학생 등록

앱에 교수님 계정으로 로그인 → 멤버 관리 → 학생 추가(이름·이메일) → 화면에 나온 **임시 비밀번호**를 학생에게 전달 → 학생은 첫 로그인 때 비밀번호를 바꾼다.

## 참고: 무료 요금제

- Supabase 무료 프로젝트는 **7일 동안 아무도 접속하지 않으면 일시정지**된다. 대시보드에서 Restore 버튼으로 다시 켠다 (데이터는 그대로). 방학 전에 기억해 둘 것
- 파일 저장 1GB, 파일 하나 최대 50MB. 큰 데이터·코드는 Drive/GitHub 링크로 제출
