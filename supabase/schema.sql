-- 랩데스크 DB 구조
-- Supabase 대시보드 → SQL Editor → New query 에 이 파일 전체를 붙여넣고 Run.
--
-- 권한 요약
--   교수(prof): 모든 프로젝트를 보고, 프로젝트·작업을 만들고, 제출물을 완료/수정요청 처리
--   학생(student): 자기가 속한 프로젝트만 보임. 자기 작업 시작·제출, 댓글, 대화
--   작업 지시·제출·확인은 아래 함수(rpc)로만 가능하고, 대화방 기록과 알림은 DB가 자동으로 남긴다.

-- ───────── 테이블 ─────────
create table public.profiles (
  id uuid primary key references auth.users on delete cascade,
  name text not null,
  role text not null default 'student' check (role in ('prof', 'student')),
  title text,                                   -- 박사과정, 석사과정 등
  created_at timestamptz not null default now()
);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  created_at timestamptz not null default now()
);

create table public.project_members (
  project_id uuid references public.projects on delete cascade,
  user_id uuid references public.profiles on delete cascade,
  notify text not null default 'all' check (notify in ('all', 'mention', 'off')),
  last_read_at timestamptz not null default now(),  -- 대화방 안 읽은 수 계산용
  primary key (project_id, user_id)
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects on delete cascade,
  title text not null,
  description text,
  due_at timestamptz not null,
  status text not null default 'assigned' check (status in ('assigned', 'doing', 'submitted', 'revise', 'done')),
  created_by uuid references public.profiles on delete set null,
  created_at timestamptz not null default now()
);
create index on public.tasks (project_id, due_at);

create table public.task_assignees (
  task_id uuid references public.tasks on delete cascade,
  user_id uuid references public.profiles on delete cascade,
  primary key (task_id, user_id)
);

create table public.submissions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks on delete cascade,
  version int not null,
  submitted_by uuid not null references public.profiles,
  memo text,
  link text,
  files jsonb not null default '[]',            -- [{"path": "...", "name": "...", "size": 123}] (Storage 'submissions' 버킷)
  created_at timestamptz not null default now(),
  unique (task_id, version)
);

create table public.task_comments (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks on delete cascade,
  author uuid not null default auth.uid() references public.profiles,
  body text not null,
  created_at timestamptz not null default now()
);

create table public.messages (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects on delete cascade,
  author uuid not null default auth.uid() references public.profiles,
  kind text not null default 'msg' check (kind in ('msg', 'event')),  -- event: 지시·제출·완료 자동 기록
  body text not null,
  task_id uuid references public.tasks on delete set null,
  created_at timestamptz not null default now()
);
create index on public.messages (project_id, created_at);

create table public.notifications (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles on delete cascade,
  project_id uuid references public.projects on delete cascade,
  task_id uuid references public.tasks on delete cascade,
  body text not null,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on public.notifications (user_id, created_at desc);

-- ───────── 권한 확인용 함수 ─────────
create function public.is_prof() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'prof')
$$;

create function public.is_member(pid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_prof() or exists (select 1 from project_members where project_id = pid and user_id = auth.uid())
$$;

create function public.task_project(tid uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select project_id from tasks where id = tid
$$;

create function public.is_assignee(tid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from task_assignees where task_id = tid and user_id = auth.uid())
$$;

-- 내부용: 알림·자동 기록 (앱에서 직접 호출 불가)
create function public._notify(uid uuid, pid uuid, tid uuid, msg text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, project_id, task_id, body)
  select uid, pid, tid, msg where uid is distinct from auth.uid()
$$;

create function public._event(pid uuid, tid uuid, msg text) returns void
language sql security definer set search_path = public as $$
  insert into messages (project_id, author, kind, body, task_id) values (pid, auth.uid(), 'event', msg, tid)
$$;

revoke execute on function public._notify(uuid, uuid, uuid, text), public._event(uuid, uuid, text) from public, anon, authenticated;

-- ───────── 가입하면 프로필 자동 생성 (기본 역할: 학생) ─────────
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name) values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1)));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ───────── 작업 흐름 (앱에서 supabase.rpc('이름', {...}) 로 호출) ─────────
-- 작업 지시 (교수)
create function public.assign_task(p_project uuid, p_title text, p_description text, p_due timestamptz, p_assignees uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare tid uuid; who text; u uuid;
begin
  if not is_prof() then raise exception '교수만 작업을 지시할 수 있습니다'; end if;
  if coalesce(array_length(p_assignees, 1), 0) = 0 then raise exception '담당자를 한 명 이상 지정하세요'; end if;
  if exists (select 1 from unnest(p_assignees) a where not exists (select 1 from project_members m where m.project_id = p_project and m.user_id = a)) then
    raise exception '프로젝트 참여자에게만 지시할 수 있습니다';
  end if;
  insert into tasks (project_id, title, description, due_at, created_by) values (p_project, p_title, p_description, p_due, auth.uid()) returning id into tid;
  insert into task_assignees (task_id, user_id) select tid, unnest(p_assignees);
  select string_agg(name, ', ') into who from profiles where id = any (p_assignees);
  perform _event(p_project, tid, format('「%s」를 %s 님에게 지시했습니다 (마감 %s)', p_title, who, to_char(p_due at time zone 'Asia/Seoul', 'MM/DD')));
  foreach u in array p_assignees loop
    perform _notify(u, p_project, tid, format('새 작업: 「%s」 마감 %s', p_title, to_char(p_due at time zone 'Asia/Seoul', 'MM/DD')));
  end loop;
  return tid;
end $$;

-- 작업 시작 (담당 학생)
create function public.start_task(p_task uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_assignee(p_task) then raise exception '담당자만 시작할 수 있습니다'; end if;
  update tasks set status = 'doing' where id = p_task and status = 'assigned';
end $$;

-- 결과 제출 (담당 학생). 다시 내면 버전이 하나씩 올라간다
create function public.submit_task(p_task uuid, p_memo text, p_link text, p_files jsonb default '[]') returns int
language plpgsql security definer set search_path = public as $$
declare t tasks; v int; p uuid;
begin
  if not is_assignee(p_task) then raise exception '담당자만 제출할 수 있습니다'; end if;
  select * into t from tasks where id = p_task for update;
  if t.status = 'done' then raise exception '이미 완료된 작업입니다'; end if;
  if coalesce(p_link, '') = '' and coalesce(jsonb_array_length(p_files), 0) = 0 then raise exception '파일이나 링크 중 하나는 있어야 합니다'; end if;
  select coalesce(max(version), 0) + 1 into v from submissions where task_id = p_task;
  insert into submissions (task_id, version, submitted_by, memo, link, files) values (p_task, v, auth.uid(), p_memo, p_link, coalesce(p_files, '[]'));
  update tasks set status = 'submitted' where id = p_task;
  perform _event(t.project_id, p_task, format('「%s」 결과를 제출했습니다 (v%s)', t.title, v));
  for p in select id from profiles where role = 'prof' loop
    perform _notify(p, t.project_id, p_task, format('%s 님이 「%s」를 제출했습니다 (v%s) · 확인 필요', (select name from profiles where id = auth.uid()), t.title, v));
  end loop;
  return v;
end $$;

-- 완료 처리 / 수정 요청 (교수)
create function public.review_task(p_task uuid, p_approve boolean, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare t tasks; a uuid;
begin
  if not is_prof() then raise exception '교수만 확인할 수 있습니다'; end if;
  if not p_approve and coalesce(trim(p_note), '') = '' then raise exception '수정할 내용을 적어 주세요'; end if;
  update tasks set status = case when p_approve then 'done' else 'revise' end where id = p_task returning * into t;
  if t.id is null then raise exception '작업을 찾을 수 없습니다'; end if;
  if coalesce(trim(p_note), '') <> '' then
    perform set_config('labdesk.in_review', 'on', true);
    insert into task_comments (task_id, author, body) values (p_task, auth.uid(), case when p_approve then p_note else '[수정 요청] ' || p_note end);
    perform set_config('labdesk.in_review', 'off', true);
  end if;
  perform _event(t.project_id, p_task, format(case when p_approve then '「%s」를 완료 처리했습니다' else '「%s」에 수정을 요청했습니다' end, t.title));
  for a in select user_id from task_assignees where task_id = p_task loop
    perform _notify(a, t.project_id, p_task, case when p_approve then format('「%s」 완료 처리됨', t.title) else format('「%s」 수정 요청: %s', t.title, p_note) end);
  end loop;
end $$;

-- 작업 댓글 → 담당자와 교수에게 알림
create function public.on_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare t tasks; u uuid;
begin
  if current_setting('labdesk.in_review', true) = 'on' then return new; end if;  -- review_task 가 따로 알림
  select * into t from tasks where id = new.task_id;
  for u in select user_id from task_assignees where task_id = t.id union select id from profiles where role = 'prof' loop
    perform _notify(u, t.project_id, t.id, format('%s 님의 댓글 · 「%s」: %s', (select name from profiles where id = new.author), t.title, left(new.body, 80)));
  end loop;
  return new;
end $$;
create trigger after_comment after insert on public.task_comments for each row execute function public.on_comment();

-- 대화방 @이름 호출 → 알림 (일반 메시지는 알림 목록에 쌓지 않고 방의 안 읽은 수로만 표시)
create function public.on_message() returns trigger
language plpgsql security definer set search_path = public as $$
declare u record;
begin
  if new.kind <> 'msg' then return new; end if;
  for u in select p.id from profiles p
           where new.body like '%@' || p.name || '%'
             and (p.role = 'prof' or exists (select 1 from project_members m where m.project_id = new.project_id and m.user_id = p.id)) loop
    perform _notify(u.id, new.project_id, null, format('%s 님이 회원님을 호출했습니다: %s', (select name from profiles where id = new.author), left(new.body, 80)));
  end loop;
  return new;
end $$;
create trigger after_message after insert on public.messages for each row execute function public.on_message();

-- ───────── 행 단위 권한 (RLS) ─────────
alter table public.profiles enable row level security;
alter table public.projects enable row level security;
alter table public.project_members enable row level security;
alter table public.tasks enable row level security;
alter table public.task_assignees enable row level security;
alter table public.submissions enable row level security;
alter table public.task_comments enable row level security;
alter table public.messages enable row level security;
alter table public.notifications enable row level security;

-- 수정 가능한 칸을 제한 (역할 role, 소속 project_id 등은 앱에서 못 바꿈)
revoke update on public.profiles, public.project_members, public.notifications from authenticated, anon;
grant update (name, title) on public.profiles to authenticated;
grant update (notify, last_read_at) on public.project_members to authenticated;
grant update (read_at) on public.notifications to authenticated;

create policy "멤버 목록 보기" on public.profiles for select to authenticated using (true);
create policy "내 프로필 수정" on public.profiles for update to authenticated using (id = auth.uid());

create policy "참여 프로젝트 보기" on public.projects for select to authenticated using (is_member(id));
create policy "교수: 프로젝트 만들기" on public.projects for insert to authenticated with check (is_prof());
create policy "교수: 프로젝트 수정" on public.projects for update to authenticated using (is_prof());
create policy "교수: 프로젝트 삭제" on public.projects for delete to authenticated using (is_prof());

create policy "참여자 보기" on public.project_members for select to authenticated using (is_member(project_id));
create policy "교수: 참여자 추가" on public.project_members for insert to authenticated with check (is_prof());
create policy "교수: 참여자 빼기" on public.project_members for delete to authenticated using (is_prof());
create policy "내 알림 설정·읽음 표시" on public.project_members for update to authenticated using (user_id = auth.uid());

create policy "작업 보기" on public.tasks for select to authenticated using (is_member(project_id));
create policy "교수: 작업 수정" on public.tasks for update to authenticated using (is_prof());
create policy "교수: 작업 삭제" on public.tasks for delete to authenticated using (is_prof());

create policy "담당자 보기" on public.task_assignees for select to authenticated using (is_member(task_project(task_id)));
create policy "교수: 담당자 추가" on public.task_assignees for insert to authenticated with check (is_prof());
create policy "교수: 담당자 빼기" on public.task_assignees for delete to authenticated using (is_prof());

create policy "제출물 보기" on public.submissions for select to authenticated using (is_member(task_project(task_id)));

create policy "댓글 보기" on public.task_comments for select to authenticated using (is_member(task_project(task_id)));
create policy "댓글 쓰기" on public.task_comments for insert to authenticated with check (author = auth.uid() and is_member(task_project(task_id)));

create policy "대화 보기" on public.messages for select to authenticated using (is_member(project_id));
create policy "대화 쓰기" on public.messages for insert to authenticated with check (author = auth.uid() and kind = 'msg' and is_member(project_id));

create policy "내 알림 보기" on public.notifications for select to authenticated using (user_id = auth.uid());
create policy "내 알림 읽음" on public.notifications for update to authenticated using (user_id = auth.uid());

-- ───────── 실시간 (대화·알림·작업 상태가 새로고침 없이 바로 반영) ─────────
alter publication supabase_realtime add table public.messages, public.notifications, public.tasks;

-- ───────── 제출 파일 저장소 ─────────
-- 경로 규칙: {project_id}/{task_id}/{파일이름}. 파일 1개 최대 50MB (무료 요금제 한도)
insert into storage.buckets (id, name, public, file_size_limit) values ('submissions', 'submissions', false, 52428800)
on conflict (id) do nothing;

create policy "제출 파일 보기" on storage.objects for select to authenticated
  using (bucket_id = 'submissions' and public.is_member(((storage.foldername(name))[1])::uuid));
create policy "제출 파일 올리기" on storage.objects for insert to authenticated
  with check (bucket_id = 'submissions' and public.is_member(((storage.foldername(name))[1])::uuid));
