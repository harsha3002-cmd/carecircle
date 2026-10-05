-- Run once in the Supabase SQL Editor. This expects a new care_plans table.
-- If a table with that name already has a different schema, migrate it first.
begin;

create table if not exists public.care_plans (
  id uuid primary key,
  created_at timestamptz not null default now(),
  quota_day date not null default (now() at time zone 'Asia/Kolkata')::date,
  visitor_id uuid not null,
  input jsonb not null,
  output jsonb not null,
  -- Unique selected categories per plan; counts do not favour repeated tasks.
  task_category text[] not null,
  input_tokens integer check (input_tokens >= 0),
  output_tokens integer check (output_tokens >= 0),
  thought_tokens integer check (thought_tokens >= 0),
  total_tokens integer check (total_tokens >= 0),
  model text not null,
  status text not null default 'success' check (status = 'success'),
  constraint care_plans_categories check (
    cardinality(task_category) between 1 and 5 and
    task_category <@ array['Daily check-in','Meal coordination','Grocery support','Appointment coordination','Household support']::text[]
  )
);
create index if not exists care_plans_visitor_day on public.care_plans (visitor_id, quota_day);

-- A durable lease coordinates all Vercel instances. Only one active generation
-- per visitor; crashed generations free their lease after 90 seconds.
create table if not exists public.care_plan_limits (
  visitor_id uuid primary key,
  request_id uuid,
  expires_at timestamptz
);
alter table public.care_plans enable row level security;
alter table public.care_plan_limits enable row level security;
revoke all on public.care_plans, public.care_plan_limits from public, anon, authenticated;
grant select, insert on public.care_plans to service_role;
grant select, insert, update on public.care_plan_limits to service_role;

create or replace function public.carecircle_stats(p_visitor uuid)
returns jsonb language sql stable security invoker set search_path = public, pg_temp as $$
  with totals as (
    select count(*) as total,
      count(*) filter (where visitor_id = p_visitor and quota_day = (now() at time zone 'Asia/Kolkata')::date) as today
    from public.care_plans where status = 'success'
  ), popular as (
    select category, count(*) as selections
    from public.care_plans c
    cross join lateral unnest(c.task_category) as selected(category)
    where c.status = 'success'
    group by category
    order by selections desc, category asc limit 1
  )
  select jsonb_build_object(
    'total_plans', totals.total,
    'most_common_category', (select category from popular),
    'category_selections', coalesce((select selections from popular), 0),
    'remaining_today', greatest(0, 5 - totals.today),
    'resets_at', (((now() at time zone 'Asia/Kolkata')::date + 1)::timestamp at time zone 'Asia/Kolkata'),
    'source', 'Supabase care_plans'
  ) from totals;
$$;

create or replace function public.carecircle_reserve(p_visitor uuid, p_request uuid)
returns jsonb language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  lease public.care_plan_limits%rowtype;
  saved public.care_plans%rowtype;
  used integer;
begin
  insert into public.care_plan_limits(visitor_id) values (p_visitor) on conflict do nothing;
  select * into lease from public.care_plan_limits where visitor_id = p_visitor for update;
  select * into saved from public.care_plans where id = p_request;
  if found then
    if saved.visitor_id <> p_visitor then return jsonb_build_object('state', 'collision'); end if;
    return jsonb_build_object('state', 'replay', 'plan', saved.output, 'statistics', public.carecircle_stats(p_visitor));
  end if;
  select count(*) into used from public.care_plans
    where visitor_id = p_visitor and quota_day = (now() at time zone 'Asia/Kolkata')::date and status = 'success';
  if used >= 5 then return jsonb_build_object('state', 'limit', 'statistics', public.carecircle_stats(p_visitor)); end if;
  if lease.request_id is not null and lease.expires_at > now() then return jsonb_build_object('state', 'busy'); end if;
  update public.care_plan_limits set request_id = p_request, expires_at = now() + interval '90 seconds' where visitor_id = p_visitor;
  return jsonb_build_object('state', 'reserved');
end;
$$;

create or replace function public.carecircle_save(
  p_visitor uuid, p_request uuid, p_input jsonb, p_output jsonb,
  p_categories text[], p_input_tokens integer, p_output_tokens integer,
  p_thought_tokens integer, p_total_tokens integer, p_model text
)
returns jsonb language plpgsql security invoker set search_path = public, pg_temp as $$
declare
  lease public.care_plan_limits%rowtype;
  saved public.care_plans%rowtype;
  used integer;
begin
  select * into lease from public.care_plan_limits where visitor_id = p_visitor for update;
  if not found then return jsonb_build_object('state', 'expired'); end if;
  select * into saved from public.care_plans where id = p_request and visitor_id = p_visitor;
  if found then return jsonb_build_object('state', 'saved', 'plan', saved.output, 'statistics', public.carecircle_stats(p_visitor)); end if;
  if lease.request_id is distinct from p_request or lease.expires_at <= now() then return jsonb_build_object('state', 'expired'); end if;
  select count(*) into used from public.care_plans
    where visitor_id = p_visitor and quota_day = (now() at time zone 'Asia/Kolkata')::date and status = 'success';
  if used >= 5 then
    update public.care_plan_limits set request_id = null, expires_at = null where visitor_id = p_visitor;
    return jsonb_build_object('state', 'limit');
  end if;
  insert into public.care_plans(id, visitor_id, input, output, task_category, input_tokens, output_tokens, thought_tokens, total_tokens, model)
    values (p_request, p_visitor, p_input, p_output, p_categories, p_input_tokens, p_output_tokens, p_thought_tokens, p_total_tokens, p_model)
    returning * into saved;
  update public.care_plan_limits set request_id = null, expires_at = null where visitor_id = p_visitor;
  return jsonb_build_object('state', 'saved', 'plan', saved.output, 'statistics', public.carecircle_stats(p_visitor));
end;
$$;

create or replace function public.carecircle_release(p_visitor uuid, p_request uuid)
returns void language sql security invoker set search_path = public, pg_temp as $$
  update public.care_plan_limits set request_id = null, expires_at = null
    where visitor_id = p_visitor and request_id = p_request;
$$;

-- PostgreSQL functions otherwise default to callable by PUBLIC.
revoke execute on function public.carecircle_stats(uuid), public.carecircle_reserve(uuid, uuid), public.carecircle_release(uuid, uuid), public.carecircle_save(uuid, uuid, jsonb, jsonb, text[], integer, integer, integer, integer, text) from public, anon, authenticated;
grant execute on function public.carecircle_stats(uuid), public.carecircle_reserve(uuid, uuid), public.carecircle_release(uuid, uuid), public.carecircle_save(uuid, uuid, jsonb, jsonb, text[], integer, integer, integer, integer, text) to service_role;
commit;

-- Evidence for the workbook (run after five successful demo submissions):
-- select created_at, task_category, input_tokens, output_tokens, thought_tokens, total_tokens from public.care_plans order by created_at desc limit 5;
-- select avg(input_tokens) as average_input_tokens, avg(output_tokens) as average_output_tokens from public.care_plans;
