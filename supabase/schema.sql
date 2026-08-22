-- ═══════════════════════════════════════════════════════════════════════════
--  사업장 안전신문고 — Supabase 스키마
--  Supabase 대시보드 → SQL Editor → 새 쿼리 → 이 파일 전체를 붙여넣고 [Run]
--  두 번 실행해도 안전합니다(멱등).
-- ═══════════════════════════════════════════════════════════════════════════

-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ 사이트 접근코드 — 현재 'kpetro'                                         │
-- │   QR 주소에 ?k=<코드> 형태로 들어갑니다.                                │
-- │                                                                         │
-- │   ★ 이미 한 번 실행한 뒤에 코드를 바꾸려면 아래 INSERT를 고치는 게      │
-- │     아니라(멱등이라 무시됨) 이 한 줄을 실행하세요:                      │
-- │       update sr_config set access_code = '새코드' where id = 1;         │
-- └─────────────────────────────────────────────────────────────────────────┘

create extension if not exists pgcrypto;

-- ═══════════════════ 테이블 ═══════════════════

create table if not exists sr_config (
  id          smallint primary key default 1,
  access_code text        not null,
  master_hash text,                                  -- null = 마스터 PIN 미설정
  updated_at  timestamptz not null default now(),
  constraint sr_config_one_row check (id = 1)
);

insert into sr_config (id, access_code)
values (1, 'kpetro')
on conflict (id) do nothing;

create table if not exists sr_dept_pin (
  dept     text        primary key,                  -- 사업장(본부)명
  pin_hash text        not null,
  set_at   timestamptz not null default now()
);

create table if not exists sr_report (
  id         uuid        primary key default gen_random_uuid(),
  no         text        unique not null,            -- SR-260822-001
  site       text        not null,
  dept       text        not null,
  reporter   text        not null,
  category   text        not null,
  content    text        not null,
  photos     text[]      not null default '{}',
  location   text        not null default '',
  status     text        not null default '처리예정',
  action     text        not null default '',
  action_by  text        not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sr_report_category check (category in ('청사안전', '시설환경', '기타')),
  constraint sr_report_status   check (status   in ('처리예정', '처리중', '처리완료'))
);

create index if not exists sr_report_created_idx on sr_report (created_at desc);
create index if not exists sr_report_site_idx    on sr_report (site);

create table if not exists sr_session (
  token      text        primary key,
  dept       text        not null,
  is_master  boolean     not null default false,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

-- ═══════════════════ RLS: 직접 접근 전면 차단 ═══════════════════
-- 정책을 하나도 만들지 않는다 = anon 키로는 테이블을 읽지도 쓰지도 못한다.
-- 모든 접근은 아래 SECURITY DEFINER 함수를 통해서만 이뤄진다.
-- (그래서 PIN 해시는 절대 브라우저로 내려오지 않는다)

alter table sr_config   enable row level security;
alter table sr_dept_pin enable row level security;
alter table sr_report   enable row level security;
alter table sr_session  enable row level security;

-- ═══════════════════ 내부 헬퍼 ═══════════════════

create or replace function sr_gate(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_code is null or not exists (
    select 1 from sr_config where id = 1 and access_code = p_code
  ) then
    raise exception 'INVALID_CODE' using errcode = '28000';
  end if;
end;
$$;

create or replace function sr_session_dept(p_token text, out v_dept text, out v_master boolean)
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from sr_session where expires_at < now();

  select dept, is_master into v_dept, v_master
  from sr_session
  where token = p_token and expires_at > now();

  if v_dept is null then
    raise exception 'NO_SESSION' using errcode = '28000';
  end if;
end;
$$;

create or replace function sr_new_token(p_dept text, p_master boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token text := encode(gen_random_bytes(24), 'hex');
  v_exp   timestamptz := now() + interval '8 hours';
begin
  insert into sr_session (token, dept, is_master, expires_at)
  values (v_token, p_dept, p_master, v_exp);

  return json_build_object(
    'ok', true, 'token', v_token, 'dept', p_dept,
    'isMaster', p_master, 'expiresAt', v_exp
  );
end;
$$;

-- ═══════════════════ 공개 API (anon 호출) ═══════════════════

-- ① 접속 확인 — 접근코드 검증 + 마스터 PIN 설정 여부
create or replace function sr_hello(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_master_set boolean;
begin
  perform sr_gate(p_code);
  select master_hash is not null into v_master_set from sr_config where id = 1;
  return json_build_object('ok', true, 'masterSet', v_master_set);
end;
$$;

-- ② 신고 목록 (전사 공유 현황판)
create or replace function sr_list(p_code text)
returns setof sr_report
language plpgsql
security definer
set search_path = public
as $$
begin
  perform sr_gate(p_code);
  return query
    select * from sr_report order by created_at desc limit 500;
end;
$$;

-- ③ 신고 접수
create or replace function sr_submit(
  p_code     text,
  p_site     text,
  p_dept     text,
  p_reporter text,
  p_category text,
  p_content  text,
  p_photos   text[] default '{}',
  p_location text   default ''
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_day    text := to_char(now() at time zone 'Asia/Seoul', 'YYMMDD');
  v_seq    int;
  v_no     text;
  v_row    sr_report;
  v_tries  int := 0;
begin
  perform sr_gate(p_code);

  if length(coalesce(p_content, '')) < 5 then
    raise exception 'CONTENT_TOO_SHORT' using errcode = '22000';
  end if;
  if length(p_content) > 2000 or length(coalesce(p_reporter, '')) > 40
     or length(coalesce(p_dept, '')) > 60 then
    raise exception 'TOO_LONG' using errcode = '22000';
  end if;
  if coalesce(array_length(p_photos, 1), 0) > 3 then
    raise exception 'TOO_MANY_PHOTOS' using errcode = '22000';
  end if;

  -- 단순 폭주 방지: 1분에 20건 초과 접수 차단
  if (select count(*) from sr_report where created_at > now() - interval '1 minute') >= 20 then
    raise exception 'RATE_LIMIT' using errcode = '53400';
  end if;

  loop
    v_tries := v_tries + 1;
    select coalesce(max(substring(no from 11 for 3)::int), 0) + 1
      into v_seq
      from sr_report
     where no like 'SR-' || v_day || '-%';

    v_no := 'SR-' || v_day || '-' || lpad(v_seq::text, 3, '0');

    begin
      insert into sr_report (no, site, dept, reporter, category, content, photos, location)
      values (v_no, p_site, p_dept, p_reporter, p_category, p_content,
              coalesce(p_photos, '{}'), coalesce(p_location, ''))
      returning * into v_row;
      exit;
    exception when unique_violation then
      if v_tries >= 5 then raise; end if;
    end;
  end loop;

  return json_build_object('ok', true, 'no', v_row.no, 'id', v_row.id);
end;
$$;

-- ④ 부서 PIN 설정 여부 확인
create or replace function sr_pin_state(p_code text, p_dept text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_set boolean;
begin
  perform sr_gate(p_code);
  select exists (select 1 from sr_dept_pin where dept = p_dept) into v_set;
  return json_build_object('ok', true, 'isSet', v_set);
end;
$$;

-- ⑤ 부서 PIN 최초 설정 (이미 있으면 거부) → 설정 후 바로 로그인
create or replace function sr_pin_init(p_code text, p_dept text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  perform sr_gate(p_code);

  if p_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN_FORMAT' using errcode = '22000';
  end if;
  if exists (select 1 from sr_dept_pin where dept = p_dept) then
    return json_build_object('ok', false, 'reason', 'ALREADY_SET');
  end if;

  insert into sr_dept_pin (dept, pin_hash)
  values (p_dept, crypt(p_pin, gen_salt('bf')));

  return sr_new_token(p_dept, false);
end;
$$;

-- ⑥ 부서 로그인
create or replace function sr_login(p_code text, p_dept text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash text;
begin
  perform sr_gate(p_code);

  select pin_hash into v_hash from sr_dept_pin where dept = p_dept;

  if v_hash is null then
    return json_build_object('ok', false, 'reason', 'NOT_SET');
  end if;
  if crypt(p_pin, v_hash) <> v_hash then
    return json_build_object('ok', false, 'reason', 'BAD_PIN');
  end if;

  return sr_new_token(p_dept, false);
end;
$$;

-- ⑦ 부서 PIN 변경 (본인 세션 필요)
create or replace function sr_pin_change(p_code text, p_token text, p_new_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dept   text;
  v_master boolean;
begin
  perform sr_gate(p_code);
  select * into v_dept, v_master from sr_session_dept(p_token);

  if v_master then
    raise exception 'MASTER_CANNOT_CHANGE_DEPT_PIN' using errcode = '42501';
  end if;
  if p_new_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN_FORMAT' using errcode = '22000';
  end if;

  update sr_dept_pin
     set pin_hash = crypt(p_new_pin, gen_salt('bf')), set_at = now()
   where dept = v_dept;

  return json_build_object('ok', true);
end;
$$;

-- ⑧ 마스터 PIN 최초 설정
create or replace function sr_master_init(p_code text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  perform sr_gate(p_code);

  if p_pin !~ '^[0-9]{6}$' then
    raise exception 'PIN_FORMAT' using errcode = '22000';
  end if;
  if exists (select 1 from sr_config where id = 1 and master_hash is not null) then
    return json_build_object('ok', false, 'reason', 'ALREADY_SET');
  end if;

  update sr_config
     set master_hash = crypt(p_pin, gen_salt('bf')), updated_at = now()
   where id = 1;

  return sr_new_token('__master__', true);
end;
$$;

-- ⑨ 마스터 로그인
create or replace function sr_master_login(p_code text, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hash text;
begin
  perform sr_gate(p_code);
  select master_hash into v_hash from sr_config where id = 1;

  if v_hash is null then
    return json_build_object('ok', false, 'reason', 'NOT_SET');
  end if;
  if crypt(p_pin, v_hash) <> v_hash then
    return json_build_object('ok', false, 'reason', 'BAD_PIN');
  end if;

  return sr_new_token('__master__', true);
end;
$$;

-- ⑩ 마스터: 부서 PIN 목록 조회
create or replace function sr_master_list(p_code text, p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dept   text;
  v_master boolean;
  v_rows   json;
begin
  perform sr_gate(p_code);
  select * into v_dept, v_master from sr_session_dept(p_token);

  if not v_master then
    raise exception 'NOT_MASTER' using errcode = '42501';
  end if;

  select coalesce(json_agg(json_build_object('dept', dept, 'setAt', set_at) order by dept), '[]'::json)
    into v_rows
    from sr_dept_pin;

  return json_build_object('ok', true, 'depts', v_rows);
end;
$$;

-- ⑪ 마스터: 부서 PIN 초기화 (다음 로그인 때 새로 설정하게 됨)
create or replace function sr_master_reset(p_code text, p_token text, p_dept text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dept   text;
  v_master boolean;
  v_hit    int;
begin
  perform sr_gate(p_code);
  select * into v_dept, v_master from sr_session_dept(p_token);

  if not v_master then
    raise exception 'NOT_MASTER' using errcode = '42501';
  end if;

  delete from sr_dept_pin where dept = p_dept;
  get diagnostics v_hit = row_count;

  delete from sr_session where dept = p_dept and is_master = false;

  return json_build_object('ok', true, 'removed', v_hit);
end;
$$;

-- ⑫ 조치 결과 저장
--    마스터는 전 사업장, 부서 담당자는 자기 사업장 건만 수정 가능
create or replace function sr_action(
  p_code   text,
  p_token  text,
  p_id     uuid,
  p_status text,
  p_action text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dept   text;
  v_master boolean;
  v_site   text;
begin
  perform sr_gate(p_code);
  select * into v_dept, v_master from sr_session_dept(p_token);

  if p_status not in ('처리예정', '처리중', '처리완료') then
    raise exception 'BAD_STATUS' using errcode = '22000';
  end if;
  if length(coalesce(p_action, '')) > 2000 then
    raise exception 'TOO_LONG' using errcode = '22000';
  end if;

  select site into v_site from sr_report where id = p_id;
  if v_site is null then
    raise exception 'NOT_FOUND' using errcode = '02000';
  end if;
  if (not v_master) and v_site <> v_dept then
    raise exception 'OTHER_SITE' using errcode = '42501';
  end if;

  update sr_report
     set status     = p_status,
         action     = coalesce(p_action, ''),
         action_by  = case when v_master then '마스터 관리자' else v_dept || ' 담당자' end,
         updated_at = now()
   where id = p_id;

  return json_build_object('ok', true);
end;
$$;

-- ⑬ 로그아웃
create or replace function sr_logout(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from sr_session where token = p_token;
  return json_build_object('ok', true);
end;
$$;

-- ═══════════════════ 권한 ═══════════════════
-- 내부 헬퍼는 외부에서 못 부르게, 공개 API만 anon 에게 연다.

revoke all on function sr_gate(text)                            from public;
revoke all on function sr_session_dept(text)                    from public;
revoke all on function sr_new_token(text, boolean)              from public;

revoke all on function sr_hello(text)                           from public;
revoke all on function sr_list(text)                            from public;
revoke all on function sr_submit(text,text,text,text,text,text,text[],text) from public;
revoke all on function sr_pin_state(text, text)                 from public;
revoke all on function sr_pin_init(text, text, text)            from public;
revoke all on function sr_login(text, text, text)               from public;
revoke all on function sr_pin_change(text, text, text)          from public;
revoke all on function sr_master_init(text, text)               from public;
revoke all on function sr_master_login(text, text)              from public;
revoke all on function sr_master_list(text, text)               from public;
revoke all on function sr_master_reset(text, text, text)        from public;
revoke all on function sr_action(text, text, uuid, text, text)  from public;
revoke all on function sr_logout(text)                          from public;

grant execute on function sr_hello(text)                          to anon, authenticated;
grant execute on function sr_list(text)                           to anon, authenticated;
grant execute on function sr_submit(text,text,text,text,text,text,text[],text) to anon, authenticated;
grant execute on function sr_pin_state(text, text)                to anon, authenticated;
grant execute on function sr_pin_init(text, text, text)           to anon, authenticated;
grant execute on function sr_login(text, text, text)              to anon, authenticated;
grant execute on function sr_pin_change(text, text, text)         to anon, authenticated;
grant execute on function sr_master_init(text, text)              to anon, authenticated;
grant execute on function sr_master_login(text, text)             to anon, authenticated;
grant execute on function sr_master_list(text, text)              to anon, authenticated;
grant execute on function sr_master_reset(text, text, text)       to anon, authenticated;
grant execute on function sr_action(text, text, uuid, text, text) to anon, authenticated;
grant execute on function sr_logout(text)                         to anon, authenticated;

-- ═══════════════════ 사진 저장소 ═══════════════════
-- 3MB 이하 이미지만, 공개 읽기 / 익명 업로드 허용

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('sr-photos', 'sr-photos', true, 3145728,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "sr_photos_read"   on storage.objects;
drop policy if exists "sr_photos_upload" on storage.objects;

create policy "sr_photos_read" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'sr-photos');

create policy "sr_photos_upload" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'sr-photos');

-- ═══════════════════ 끝 ═══════════════════
-- 확인용:
--   select access_code, master_hash is not null as master_set from sr_config;
--   select * from sr_hello('kpetro');
