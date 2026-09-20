begin;
create table if not exists public.paris_split_requests (
  id uuid primary key, trip_id uuid not null references public.trips(id),
  payload_hash text not null, created_at timestamptz not null default now()
);
alter table public.paris_split_requests enable row level security;
revoke all on public.paris_split_requests from public, anon, authenticated;
grant all on public.paris_split_requests to service_role;

create or replace function public.paris_split_v2(payload jsonb) returns jsonb
language plpgsql security invoker set search_path = public, extensions
as $fn$
declare
  act text := payload->>'action';
  t public.trips%rowtype;
  ex public.expenses%rowtype;
  eid uuid; rid uuid; old_request public.paris_split_requests%rowtype;
  item jsonb; total numeric; amt numeric; rate numeric; sm text; nm text;
  actor text := nullif(trim(payload->>'actor_name'),'');
  details jsonb := '{}'::jsonb;
  entity text; event text;
  before_data jsonb;
begin
  if jsonb_typeof(payload) <> 'object' or act is null then raise exception 'Invalid request'; end if;
  if act not in ('create_trip','get_trip','add_member','add_expense','edit_expense','settle') then raise exception 'Unknown action'; end if;
  if length(coalesce(actor,'')) > 80 then raise exception 'Name is too long'; end if;
  if act <> 'get_trip' then
    rid := (payload->>'request_id')::uuid;
    if rid is null then raise exception 'Request ID required'; end if;
    perform pg_advisory_xact_lock(hashtextextended(rid::text,0));
    select * into old_request from paris_split_requests where id=rid;
    if found then
      if old_request.payload_hash <> md5(payload::text) then raise exception 'Request ID already used'; end if;
      select * into t from trips where id=old_request.trip_id;
      act := 'get_trip';
    end if;
  end if;
  if t.id is null and act <> 'create_trip' then
    if coalesce(payload->>'invite_code','') !~ '^[A-Fa-f0-9]{40}$' then raise exception 'Invalid invite code'; end if;
    select * into t from trips where invite_code=upper(payload->>'invite_code') for update;
    if not found then raise exception 'Trip not found'; end if;
  end if;
  if act='create_trip' then
    nm := trim(payload->>'name'); actor := trim(payload->>'member_name');
    if coalesce(length(nm),0) not between 1 and 120 or coalesce(length(actor),0) not between 1 and 80 then raise exception 'Trip and member names required'; end if;
    insert into trips(name,invite_code) values(nm,upper(replace(gen_random_uuid()::text,'-','')||substr(replace(gen_random_uuid()::text,'-',''),1,8))) returning * into t;
    insert into members(trip_id,name) values(t.id,actor) returning id into eid;
    entity := 'trip'; event := 'created_trip'; details := jsonb_build_object('name',nm,'member_name',actor);
  elsif act='add_member' then
    nm := trim(payload->>'name');
    if coalesce(length(nm),0) not between 1 and 80 then raise exception 'Member name required'; end if;
    if (select count(*) from members where trip_id=t.id) >= 50 then raise exception 'This trip has reached 50 members'; end if;
    if exists(select 1 from members where trip_id=t.id and lower(name)=lower(nm)) then raise exception 'That name already belongs to this trip'; end if;
    insert into members(trip_id,name) values(t.id,nm) returning id into eid;
    entity := 'member'; event := 'added_member'; details := jsonb_build_object('name',nm);
  elsif act in ('add_expense','edit_expense') then
    amt := (payload->>'amount')::numeric; rate := (payload->>'exchange_rate_to_eur')::numeric;
    nm := trim(payload->>'description'); sm := payload->>'split_method';
    if coalesce(length(nm),0) not between 1 and 160 or amt is null or amt <= 0 or amt > 1000000 or amt <> round(amt,2) then raise exception 'Enter a description and positive amount with at most two decimals'; end if;
    if rate is null or rate <= 0 or rate > 1000 or rate <> round(rate,8) then raise exception 'Invalid exchange rate'; end if;
    if payload->>'currency' is null or payload->>'currency' not in ('EUR','GBP','CAD','USD') then raise exception 'Unsupported currency'; end if;
    if payload->>'currency'='EUR' and rate <> 1 then raise exception 'EUR rate must be 1'; end if;
    if sm is null or sm not in ('equal','shares','percentage','exact') then raise exception 'Invalid split method'; end if;
    if coalesce(jsonb_typeof(payload->'participants'),'') <> 'array' or coalesce(jsonb_typeof(payload->'payers'),'') <> 'array' then raise exception 'Participants and payers required'; end if;
    if jsonb_array_length(payload->'participants') not between 1 and 50 or jsonb_array_length(payload->'payers') not between 1 and 50 then raise exception 'Choose participants and payers'; end if;
    if (select count(distinct x->>'member_id') from jsonb_array_elements(payload->'participants')x) <> jsonb_array_length(payload->'participants') or (select count(distinct x->>'member_id') from jsonb_array_elements(payload->'payers')x) <> jsonb_array_length(payload->'payers') then raise exception 'Duplicate member'; end if;
    total := 0;
    for item in select value from jsonb_array_elements(payload->'payers') loop
      if not exists(select 1 from members where id=(item->>'member_id')::uuid and trip_id=t.id) then raise exception 'Invalid member'; end if;
      if (item->>'amount')::numeric is null or (item->>'amount')::numeric <= 0 or (item->>'amount')::numeric > amt or (item->>'amount')::numeric <> round((item->>'amount')::numeric,2) then raise exception 'Invalid payer amount'; end if;
      total := total + (item->>'amount')::numeric;
    end loop;
    if total <> amt then raise exception 'Payer amounts must equal the expense amount'; end if;
    total := 0;
    for item in select value from jsonb_array_elements(payload->'participants') loop
      if not exists(select 1 from members where id=(item->>'member_id')::uuid and trip_id=t.id) then raise exception 'Invalid member'; end if;
      if (item->>'value')::numeric is null or (item->>'value')::numeric < 0 or (item->>'value')::numeric > 1000000 or (item->>'value')::numeric <> round((item->>'value')::numeric,4) then raise exception 'Invalid split value'; end if;
      if sm='exact' and (item->>'value')::numeric <> round((item->>'value')::numeric,2) then raise exception 'Exact amounts need at most two decimals'; end if;
      total := total + (item->>'value')::numeric;
    end loop;
    if sm='shares' and total <= 0 then raise exception 'Shares must total more than zero'; end if;
    if sm='percentage' and total <> 100 then raise exception 'Percentages must total 100'; end if;
    if sm='exact' and total <> amt then raise exception 'Exact amounts must equal the expense amount'; end if;
    if act='edit_expense' then
      select * into ex from expenses where id=(payload->>'expense_id')::uuid and trip_id=t.id for update;
      if not found then raise exception 'Expense not found'; end if;
      if payload->>'expected_updated_at' is null or ex.updated_at <> (payload->>'expected_updated_at')::timestamptz then raise exception 'Someone changed this expense. Refresh and reopen it'; end if;
      before_data := to_jsonb(ex) || jsonb_build_object('payers',(select jsonb_agg(to_jsonb(p)) from expense_payers p where expense_id=ex.id),'participants',(select jsonb_agg(to_jsonb(s)) from expense_splits s where expense_id=ex.id));
      eid := ex.id;
      update expenses set description=nm,amount=amt,currency=payload->>'currency',exchange_rate_to_eur=rate,split_method=sm,payer_member_id=(payload->'payers'->0->>'member_id')::uuid,updated_at=clock_timestamp() where id=eid;
      delete from expense_payers where expense_id=eid;
      delete from expense_splits where expense_id=eid;
    else
      insert into expenses(trip_id,description,amount,currency,payer_member_id,split_method,exchange_rate_to_eur) values(t.id,nm,amt,payload->>'currency',(payload->'payers'->0->>'member_id')::uuid,sm,rate) returning id into eid;
    end if;
    insert into expense_payers(expense_id,member_id,amount) select eid,(x->>'member_id')::uuid,(x->>'amount')::numeric from jsonb_array_elements(payload->'payers')x;
    insert into expense_splits(expense_id,member_id,value) select eid,(x->>'member_id')::uuid,case when sm='equal' then 1 else (x->>'value')::numeric end from jsonb_array_elements(payload->'participants')x;
    entity := 'expense'; event := case when act='edit_expense' then 'edited_expense' else 'added_expense' end;
    details := (payload - 'invite_code' - 'request_id') || jsonb_build_object('before',before_data);
  elsif act='settle' then
    amt := (payload->>'amount_eur')::numeric;
    if amt is null or amt <= 0 or amt > 1000000 or amt <> round(amt,2) or payload->>'from_member_id'=payload->>'to_member_id' then raise exception 'Invalid settlement'; end if;
    if not exists(select 1 from members where id=(payload->>'from_member_id')::uuid and trip_id=t.id) or not exists(select 1 from members where id=(payload->>'to_member_id')::uuid and trip_id=t.id) then raise exception 'Invalid member'; end if;
    insert into settlements(trip_id,from_member_id,to_member_id,amount_eur) values(t.id,(payload->>'from_member_id')::uuid,(payload->>'to_member_id')::uuid,amt) returning id into eid;
    entity := 'settlement'; event := 'recorded_settlement'; details := payload - 'invite_code' - 'request_id';
  end if;
  if act <> 'get_trip' then
    insert into activity_log(trip_id,member_name,action,entity_type,entity_id,details) values(t.id,actor,event,entity,eid,details);
    insert into paris_split_requests(id,trip_id,payload_hash) values(rid,t.id,md5(payload::text));
    -- Broadcast only an invalidation, never expense data or the invite credential.
    perform realtime.send('{"changed":true}'::jsonb,'changed','paris:'||t.id::text,false);
  end if;
  return jsonb_build_object(
    'trip',to_jsonb(t),
    'members',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at,m.id) from members m where trip_id=t.id),'[]'::jsonb),
    'expenses',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc,e.id) from expenses e where trip_id=t.id),'[]'::jsonb),
    'splits',coalesce((select jsonb_agg(to_jsonb(s)) from expense_splits s join expenses e on e.id=s.expense_id where e.trip_id=t.id),'[]'::jsonb),
    'payers',coalesce((select jsonb_agg(to_jsonb(p)) from expense_payers p join expenses e on e.id=p.expense_id where e.trip_id=t.id),'[]'::jsonb),
    'settlements',coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from settlements s where trip_id=t.id),'[]'::jsonb),
    'activity',coalesce((select jsonb_agg(to_jsonb(a) order by a.id desc) from activity_log a where trip_id=t.id),'[]'::jsonb)
  );
end;
$fn$;
revoke all on function public.paris_split_v2(jsonb) from public,anon,authenticated;
grant execute on function public.paris_split_v2(jsonb) to service_role;
commit;
