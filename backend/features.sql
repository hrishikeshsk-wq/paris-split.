begin;
alter table public.trips add column if not exists archived_at timestamptz;
alter table public.members add column if not exists removed_at timestamptz;
alter table public.expenses add column if not exists deleted_at timestamptz;
create table if not exists public.paris_creators(trip_id uuid primary key references public.trips(id), member_id uuid not null references public.members(id), owner_key text not null);
create table if not exists public.paris_sessions(token_hash text primary key, trip_id uuid not null references public.trips(id), member_id uuid not null references public.members(id), revoked_at timestamptz, created_at timestamptz not null default now());
create table if not exists public.paris_v3_requests(id uuid primary key, trip_id uuid not null references public.trips(id), fingerprint text not null);
create table if not exists public.paris_rate_limits(key text primary key, hits integer not null, expires_at timestamptz not null);
alter table public.paris_creators enable row level security;
alter table public.paris_sessions enable row level security;
alter table public.paris_v3_requests enable row level security;
alter table public.paris_rate_limits enable row level security;
revoke all on public.paris_creators,public.paris_sessions,public.paris_v3_requests,public.paris_rate_limits from public,anon,authenticated;
grant all on public.paris_creators,public.paris_sessions,public.paris_v3_requests,public.paris_rate_limits to service_role;

create or replace function public.paris_rate_limit(bucket text, maximum integer) returns boolean
language plpgsql security invoker set search_path=public as $rate$
declare n integer;
begin
 insert into paris_rate_limits(key,hits,expires_at) values(bucket,1,now()+interval '2 hours')
 on conflict(key) do update set hits=paris_rate_limits.hits+1 returning hits into n;
 delete from paris_rate_limits where expires_at<now();
 return n<=maximum;
end;$rate$;
revoke all on function public.paris_rate_limit(text,integer) from public,anon,authenticated;
grant execute on function public.paris_rate_limit(text,integer) to service_role;

create or replace function public.paris_split_v3(payload jsonb) returns jsonb
language plpgsql security invoker set search_path=public,extensions as $fn$
declare
 act text:=payload->>'action'; t public.trips%rowtype; m public.members%rowtype;
 creator public.paris_creators%rowtype; old_req public.paris_v3_requests%rowtype;
 result jsonb; clean jsonb:=payload-'session_token'-'owner_key'-'invite_code';
 req uuid; fp text; token text; owner text; target public.members%rowtype; ex public.expenses%rowtype;
 is_owner boolean:=false; mutation boolean:=false; before_data jsonb;
begin
 if jsonb_typeof(payload)<>'object' or act is null then raise exception 'Invalid request'; end if;
 if act='create_trip' then
  result:=paris_split_v2(clean); select * into t from trips where id=(result->'trip'->>'id')::uuid for update;
  select * into m from members where trip_id=t.id order by created_at,id limit 1;
  select * into creator from paris_creators where trip_id=t.id;
  if not found then
   owner:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
   insert into paris_creators values(t.id,m.id,owner) returning * into creator;
  end if;
  owner:=creator.owner_key; is_owner:=true;
 elsif act='join_trip' then
  select * into t from trips where invite_code=upper(payload->>'invite_code') for update;
  if not found then raise exception 'This invite is invalid or has been replaced. Ask a friend for the latest link'; end if;
  if coalesce(length(trim(payload->>'name')),0) not between 1 and 80 then raise exception 'Enter your name'; end if;
  select * into m from members where trip_id=t.id and lower(name)=lower(trim(payload->>'name'));
  if found and m.removed_at is not null then raise exception 'That member has been removed. Ask the creator to restore them'; end if;
  if m.id is null then
   result:=paris_split_v2(jsonb_build_object('action','add_member','request_id',payload->>'request_id','invite_code',t.invite_code,'name',trim(payload->>'name'),'actor_name',trim(payload->>'name')));
   select * into m from members where trip_id=t.id and lower(name)=lower(trim(payload->>'name'));
  end if;
 else
  if nullif(payload->>'session_token','') is not null then
   select mm.* into m from paris_sessions s join members mm on mm.id=s.member_id where s.token_hash=encode(digest(payload->>'session_token','sha256'),'hex') and s.revoked_at is null and mm.removed_at is null;
   if not found then raise exception 'Your access was removed or expired. Ask the creator for a new invite'; end if;
   select * into t from trips where id=m.trip_id for update;
  else
   select * into t from trips where invite_code=upper(payload->>'invite_code') for update;
   if not found then raise exception 'This invite is invalid or has been replaced. Ask a friend for the latest link'; end if;
   if act not in ('get_trip','restore_creator') then raise exception 'Join the trip with your name before making changes'; end if;
  end if;
  select * into creator from paris_creators where trip_id=t.id;
  is_owner:=coalesce(creator.owner_key=payload->>'owner_key',false);
  if act='restore_creator' then
   if not is_owner then raise exception 'That creator recovery key is not valid'; end if;
   select * into m from members where id=creator.member_id;
  elsif act<>'get_trip' then
   req:=(payload->>'request_id')::uuid;
   if req is null then raise exception 'Request ID required'; end if;
   perform pg_advisory_xact_lock(hashtextextended(req::text,1));
   fp:=md5((clean||jsonb_build_object('trip',t.id,'member',m.id))::text);
   select * into old_req from paris_v3_requests where id=req;
   if found then
    if old_req.fingerprint<>fp then raise exception 'Request ID already used'; end if;
   else
    if act in ('delete_expense','restore_expense') then
     select * into ex from expenses where id=(payload->>'expense_id')::uuid and trip_id=t.id for update;
     if not found then raise exception 'Expense not found'; end if;
     if payload->>'expected_updated_at' is null or ex.updated_at<>(payload->>'expected_updated_at')::timestamptz then raise exception 'Expense changed. Refresh and try again'; end if;
     if (act='delete_expense' and ex.deleted_at is not null) or (act='restore_expense' and ex.deleted_at is null) then raise exception 'Expense state already changed'; end if;
     before_data:=to_jsonb(ex)||jsonb_build_object('payers',(select jsonb_agg(to_jsonb(p)) from expense_payers p where expense_id=ex.id),'participants',(select jsonb_agg(to_jsonb(s)) from expense_splits s where expense_id=ex.id));
     update expenses set deleted_at=case when act='delete_expense' then now() else null end,updated_at=clock_timestamp() where id=ex.id;
     insert into activity_log(trip_id,member_name,action,entity_type,entity_id,details) values(t.id,m.name,case when act='delete_expense' then 'deleted_expense' else 'restored_expense' end,'expense',ex.id,jsonb_build_object('description',ex.description,'amount',ex.amount,'currency',ex.currency,'before',before_data));
     mutation:=true;
    elsif act in ('remove_member','restore_member') then
     if not is_owner then raise exception 'Only the trip creator can manage members'; end if;
     select * into target from members where id=(payload->>'member_id')::uuid and trip_id=t.id for update;
     if not found or target.id=creator.member_id then raise exception 'The creator cannot be removed'; end if;
     if (act='remove_member' and target.removed_at is not null) or (act='restore_member' and target.removed_at is null) then raise exception 'Member state already changed'; end if;
     update members set removed_at=case when act='remove_member' then now() else null end where id=target.id;
     if act='remove_member' then
      update paris_sessions set revoked_at=now() where member_id=target.id;
      update trips set invite_code=upper(replace(gen_random_uuid()::text,'-','')||substr(replace(gen_random_uuid()::text,'-',''),1,8)) where id=t.id returning * into t;
     end if;
     insert into activity_log(trip_id,member_name,action,entity_type,entity_id,details) values(t.id,m.name,case when act='remove_member' then 'removed_member' else 'restored_member' end,'member',target.id,jsonb_build_object('name',target.name));
     mutation:=true;
    elsif act in ('add_member','add_expense','edit_expense','settle') then
     if act in ('add_expense','edit_expense') and exists(select 1 from jsonb_array_elements(coalesce(payload->'participants','[]'::jsonb)||coalesce(payload->'payers','[]'::jsonb))x join members mm on mm.id=(x->>'member_id')::uuid where mm.removed_at is not null) then raise exception 'Removed members cannot be included in new or edited expenses'; end if;
     if act='edit_expense' and exists(select 1 from expenses where id=(payload->>'expense_id')::uuid and deleted_at is not null) then raise exception 'Restore this expense before editing it'; end if;
     result:=paris_split_v2(clean||jsonb_build_object('invite_code',t.invite_code,'actor_name',m.name));
    else raise exception 'Unknown action'; end if;
    insert into paris_v3_requests values(req,t.id,fp);
   end if;
  end if;
 end if;
 if t.archived_at is not null then raise exception 'This test trip was reset. Start a new trip'; end if;
 select * into creator from paris_creators where trip_id=t.id;
 is_owner:=is_owner or coalesce(creator.owner_key=payload->>'owner_key',false);
 if act in ('create_trip','join_trip','restore_creator') then
  token:=replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','');
  insert into paris_sessions(token_hash,trip_id,member_id) values(encode(digest(token,'sha256'),'hex'),t.id,m.id);
 end if;
 if mutation then perform realtime.send('{"changed":true}'::jsonb,'changed','paris:'||t.id::text,false); end if;
 result:=paris_split_v2(jsonb_build_object('action','get_trip','invite_code',t.invite_code));
 result:=result||jsonb_build_object('expenses',coalesce((select jsonb_agg(x) from jsonb_array_elements(result->'expenses')x where x->>'deleted_at' is null),'[]'::jsonb),'deleted_expenses',coalesce((select jsonb_agg(x) from jsonb_array_elements(result->'expenses')x where x->>'deleted_at' is not null),'[]'::jsonb),'is_creator',coalesce(is_owner,false),'creator_member_id',creator.member_id,'current_member_id',m.id);
 if token is not null then result:=result||jsonb_build_object('session_token',token); end if;
 if owner is not null then result:=result||jsonb_build_object('owner_key',owner); end if;
 return result;
end;$fn$;
revoke all on function public.paris_split_v3(jsonb) from public,anon,authenticated;
grant execute on function public.paris_split_v3(jsonb) to service_role;
commit;
