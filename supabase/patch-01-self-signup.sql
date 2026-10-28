-- 패치 1: 학생이 직접 가입하는 방식
-- 가입만 한 사람(아직 어느 프로젝트에도 없는 사람)은 자기 프로필만 보인다.
-- 같은 프로젝트 사람과 교수 프로필은 보이고, 교수는 전원(가입 대기 포함)을 본다.
-- SQL Editor 에 붙여넣고 Run. (schema.sql 을 새로 실행하는 경우에는 이미 들어 있으므로 필요 없음)

create or replace function public.can_see_profile(target uuid, target_role text) returns boolean
language sql stable security definer set search_path = public as $$
  select target = auth.uid()
      or (target_role = 'prof' and exists (select 1 from project_members where user_id = auth.uid()))
      or is_prof()
      or exists (select 1 from project_members a join project_members b on a.project_id = b.project_id
                 where a.user_id = auth.uid() and b.user_id = target)
$$;
grant execute on function public.can_see_profile(uuid, text) to authenticated, service_role;

drop policy if exists "멤버 목록 보기" on public.profiles;
create policy "멤버 목록 보기" on public.profiles for select to authenticated using (can_see_profile(id, role));
