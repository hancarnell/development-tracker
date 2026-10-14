-- Valiant Construction Planner: database setup. Paste into Supabase > SQL Editor > Run. Safe to run once on a new project.

-- 1. People and roles. The first account to sign up becomes admin. Everyone after starts as 'pending'
--    and cannot see any data until an admin changes the role to viewer or editor.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  role text not null default 'pending' check (role in ('pending','viewer','editor','admin')),
  created_at timestamptz not null default now()
);
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, role)
  values (new.id, new.email, case when (select count(*) from public.profiles) = 0 then 'admin' else 'pending' end);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create function public.my_role() returns text language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;
alter table public.profiles enable row level security;
create policy "own or admin read" on public.profiles for select to authenticated using (id = auth.uid() or public.my_role() = 'admin');
create policy "admin update" on public.profiles for update to authenticated using (public.my_role() = 'admin') with check (public.my_role() = 'admin');

-- 2. Plan data. One row per project, capital event and the settings doc. Fields live in a JSON column.
create table public.projects (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now(), updated_by uuid);
create table public.capital  (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now(), updated_by uuid);
create table public.settings (id text primary key, data jsonb not null default '{}', updated_at timestamptz not null default now(), updated_by uuid);

create function public.touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); new.updated_by = auth.uid(); return new; end $$;

-- 3. Change history: who changed what, with the old and new values.
create table public.history (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  by_id uuid, by_email text, tbl text, row_id text, op text, old_data jsonb, new_data jsonb
);
create function public.log_change() returns trigger language plpgsql security definer set search_path = public as $$
declare who text;
begin
  select email into who from public.profiles where id = auth.uid();
  if tg_op = 'INSERT' then
    insert into public.history (by_id, by_email, tbl, row_id, op, new_data) values (auth.uid(), who, tg_table_name, new.id, 'INSERT', new.data);
  elsif tg_op = 'UPDATE' then
    if old.data is distinct from new.data then
      insert into public.history (by_id, by_email, tbl, row_id, op, old_data, new_data) values (auth.uid(), who, tg_table_name, new.id, 'UPDATE', old.data, new.data);
    end if;
  else
    insert into public.history (by_id, by_email, tbl, row_id, op, old_data) values (auth.uid(), who, tg_table_name, old.id, 'DELETE', old.data);
  end if;
  return null;
end $$;

do $$ declare t text; begin
  foreach t in array array['projects','capital','settings'] loop
    execute format('create trigger touch_%1$s before insert or update on public.%1$s for each row execute function public.touch()', t);
    execute format('create trigger log_%1$s after insert or update or delete on public.%1$s for each row execute function public.log_change()', t);
    execute format('alter table public.%1$s enable row level security', t);
    execute format('create policy "members read" on public.%1$s for select to authenticated using (public.my_role() in (''viewer'',''editor'',''admin''))', t);
    execute format('create policy "editors insert" on public.%1$s for insert to authenticated with check (public.my_role() in (''editor'',''admin''))', t);
    execute format('create policy "editors update" on public.%1$s for update to authenticated using (public.my_role() in (''editor'',''admin'')) with check (public.my_role() in (''editor'',''admin''))', t);
    execute format('create policy "editors delete" on public.%1$s for delete to authenticated using (public.my_role() in (''editor'',''admin''))', t);
  end loop;
end $$;
alter table public.history enable row level security;
create policy "members read history" on public.history for select to authenticated using (public.my_role() in ('viewer','editor','admin'));

-- 4. Field-level save: merges changed fields into a row so two people editing different fields do not overwrite each other.
create function public.patch_doc(t text, rid text, patch jsonb) returns void language plpgsql security invoker set search_path = public as $$
begin
  if t = 'projects' then update public.projects set data = data || patch where id = rid;
  elsif t = 'capital' then update public.capital set data = data || patch where id = rid;
  elsif t = 'settings' then update public.settings set data = data || patch where id = rid;
  else raise exception 'unknown table %', t;
  end if;
end $$;

-- 5. Live updates between open browsers.
alter publication supabase_realtime add table public.projects, public.capital, public.settings;
