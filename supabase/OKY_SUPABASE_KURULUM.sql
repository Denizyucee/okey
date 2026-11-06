-- OKY / Classic Okey - Supabase database setup
-- Run this entire script once in Supabase Dashboard > SQL Editor > New query.
-- Uses Supabase anonymous auth sessions (JWT role: authenticated).
-- Do NOT expose the service_role / secret key in the frontend.

create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- Core tables
-- -----------------------------------------------------------------------------
create table if not exists public.okey_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  owner_token text not null,
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  created_at timestamptz not null default now(),
  started_at timestamptz
);

create table if not exists public.okey_players (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.okey_rooms(id) on delete cascade,
  player_token text not null,
  nickname text not null,
  avatar text not null default 'sun',
  seat integer check (seat between 0 and 3),
  is_spectator boolean not null default false,
  -- Legacy column retained for compatibility; private hands are stored separately.
  hand jsonb not null default '[]'::jsonb,
  score integer not null default 0,
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique(room_id, player_token)
);

create table if not exists public.okey_games (
  room_id uuid primary key references public.okey_rooms(id) on delete cascade,
  current_seat integer not null default 0 check (current_seat between 0 and 3),
  indicator_tile jsonb not null default '{"color":"red","value":5,"id":"red-5"}'::jsonb,
  okey_tile jsonb not null default '{"color":"red","value":6,"id":"red-6"}'::jsonb,
  remaining_tiles integer not null default 106,
  draw_pile jsonb not null default '[]'::jsonb,
  discarded_tiles jsonb not null default '[]'::jsonb,
  last_discarded_tile jsonb,
  must_draw boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Bring an existing partial installation up to the same schema.
alter table public.okey_games add column if not exists draw_pile jsonb not null default '[]'::jsonb;
alter table public.okey_games add column if not exists last_discarded_tile jsonb;
alter table public.okey_games add column if not exists must_draw boolean not null default true;

create table if not exists public.okey_private_hands (
  player_id uuid primary key references public.okey_players(id) on delete cascade,
  room_id uuid not null references public.okey_rooms(id) on delete cascade,
  player_token text not null,
  hand jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  unique(room_id, player_token)
);

-- -----------------------------------------------------------------------------
-- RLS and grants
-- -----------------------------------------------------------------------------
alter table public.okey_rooms enable row level security;
alter table public.okey_players enable row level security;
alter table public.okey_games enable row level security;
alter table public.okey_private_hands enable row level security;

-- Room creation and room-code lookup are performed by the client. The room
-- owner_token is currently part of the app's Room type; do not reuse it as a
-- password or secret. Player hands/draw pile are never granted to browser roles.
grant usage on schema public to anon, authenticated;
grant select, insert on public.okey_rooms to authenticated;
grant select on public.okey_players to authenticated;
grant select on public.okey_games to authenticated;
revoke all on public.okey_private_hands from anon, authenticated;
revoke all on public.okey_players from anon, authenticated;
revoke all on public.okey_games from anon, authenticated;
revoke all on public.okey_rooms from anon, authenticated;

-- Column-level public metadata only. No hand column is exposed.
grant select (id, code, owner_token, status, created_at, started_at) on public.okey_rooms to authenticated;
grant insert (code, owner_token) on public.okey_rooms to authenticated;
grant select (id, room_id, player_token, nickname, avatar, seat, is_spectator, score, joined_at, last_seen_at) on public.okey_players to authenticated;
grant select (room_id, current_seat, indicator_tile, okey_tile, remaining_tiles, discarded_tiles, last_discarded_tile, must_draw, created_at, updated_at) on public.okey_games to authenticated;

-- Recreate policies safely.
drop policy if exists okey_rooms_read on public.okey_rooms;
create policy okey_rooms_read on public.okey_rooms for select to authenticated using (true);
drop policy if exists okey_rooms_create on public.okey_rooms;
create policy okey_rooms_create on public.okey_rooms for insert to authenticated with check (length(code) between 4 and 20 and length(owner_token) between 1 and 100);

drop policy if exists okey_players_read on public.okey_players;
create policy okey_players_read on public.okey_players for select to authenticated using (true);

drop policy if exists okey_games_read on public.okey_games;
create policy okey_games_read on public.okey_games for select to authenticated using (true);

-- Private hand table has no browser policies; only SECURITY DEFINER RPCs access it.

-- -----------------------------------------------------------------------------
-- Join room: allocate a seat atomically and create a private hand row.
-- -----------------------------------------------------------------------------
drop function if exists public.join_okey_room(text, text, text, text);
create function public.join_okey_room(
  p_code text, p_player_token text, p_nickname text, p_avatar text
) returns public.okey_players
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_room public.okey_rooms%rowtype;
  v_player public.okey_players%rowtype;
  v_seat integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_player_token is null or length(p_player_token) < 1 or length(p_player_token) > 100 then raise exception 'Invalid player token'; end if;
  if p_nickname is null or length(trim(p_nickname)) < 1 or length(trim(p_nickname)) > 18 then raise exception 'Nickname must be 1-18 characters'; end if;

  select * into v_room from public.okey_rooms where code = upper(trim(p_code)) for update;
  if v_room.id is null then raise exception 'Room unavailable'; end if;

  select * into v_player from public.okey_players where room_id = v_room.id and player_token = p_player_token;
  if v_player.id is not null then
    update public.okey_players set nickname = trim(p_nickname), avatar = coalesce(nullif(p_avatar,''),'sun'), last_seen_at = now()
    where id = v_player.id returning * into v_player;
    return v_player;
  end if;

  select s into v_seat
  from generate_series(0,3) as g(s)
  where not exists (select 1 from public.okey_players p where p.room_id = v_room.id and p.seat = g.s)
  order by s limit 1;

  if v_seat is null and v_room.status = 'waiting' then raise exception 'Room full'; end if;

  insert into public.okey_players(room_id, player_token, nickname, avatar, seat, is_spectator)
  values (v_room.id, p_player_token, trim(p_nickname), coalesce(nullif(p_avatar,''),'sun'), v_seat, v_seat is null)
  returning * into v_player;

  insert into public.okey_private_hands(player_id, room_id, player_token, hand)
  values (v_player.id, v_room.id, p_player_token, '[]'::jsonb)
  on conflict (player_id) do nothing;

  return v_player;
end;
$$;

-- Leave room through a token-checked RPC (the browser cannot delete other seats).
drop function if exists public.leave_okey_room(uuid, text);
create function public.leave_okey_room(p_player_id uuid, p_player_token text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_deleted integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  delete from public.okey_players where id = p_player_id and player_token = p_player_token;
  get diagnostics v_deleted = row_count;
  return v_deleted = 1;
end;
$$;

-- Return only the requesting player's hand plus their public player record.
drop function if exists public.get_okey_player(uuid, text);
create function public.get_okey_player(p_room_id uuid, p_player_token text)
returns table (
  id uuid, room_id uuid, player_token text, nickname text, avatar text,
  seat integer, is_spectator boolean, hand jsonb, score integer,
  joined_at timestamptz, last_seen_at timestamptz
)
language sql security definer set search_path = public as $$
  select p.id, p.room_id, p.player_token, p.nickname, p.avatar, p.seat,
         p.is_spectator, coalesce(h.hand, '[]'::jsonb), p.score, p.joined_at, p.last_seen_at
  from public.okey_players p
  left join public.okey_private_hands h on h.player_id = p.id and h.player_token = p_player_token
  where p.room_id = p_room_id and p.player_token = p_player_token
    and auth.uid() is not null;
$$;

-- -----------------------------------------------------------------------------
-- Start a game: 106 tiles, one indicator, 15 for first player, 14 for others.
-- -----------------------------------------------------------------------------
create or replace function public.start_okey_game(p_room_id uuid, p_player_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_owner text;
  v_players uuid[];
  v_count integer;
  v_deck jsonb;
  v_indicator jsonb;
  v_okey jsonb;
  v_hand jsonb;
  v_remaining jsonb;
  v_player uuid;
  v_player_token text;
  v_index integer := 1;
  v_indicator_index integer := 0;
  v_order integer := 0;
  v_hand_size integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select owner_token into v_owner from public.okey_rooms where id = p_room_id and status = 'waiting' for update;
  if v_owner is null or v_owner <> p_player_token then raise exception 'Not authorized to start'; end if;
  select array_agg(id order by seat), count(*) into v_players, v_count
  from public.okey_players where room_id = p_room_id and seat is not null;
  if v_count < 2 or v_count > 4 then raise exception 'Invalid player count'; end if;

  select jsonb_agg(jsonb_build_object('id', color || '-' || value || '-' || copy, 'value', value, 'color', color) order by random())
  into v_deck
  from (
    select c.color, n.value, x.copy
    from unnest(array['red','blue','black','yellow']) c(color)
    cross join generate_series(1,13) n(value)
    cross join generate_series(1,2) x(copy)
    union all select 'joker', 0, 1
    union all select 'joker', 0, 2
  ) tiles;

  -- Find a non-joker indicator; remove it from the draw sequence.
  for v_indicator_index in 0..105 loop
    v_indicator := v_deck -> v_indicator_index;
    exit when v_indicator ->> 'color' <> 'joker';
  end loop;
  if v_indicator is null then raise exception 'Could not select indicator'; end if;
  v_okey := jsonb_build_object(
    'id', (v_indicator->>'color') || '-' || (((v_indicator->>'value')::integer % 13) + 1) || '-okey',
    'value', (((v_indicator->>'value')::integer % 13) + 1),
    'color', v_indicator->>'color'
  );

  -- Remove indicator, preserve shuffled order for dealing and draw pile.
  select jsonb_agg(tile order by ord) into v_remaining
  from jsonb_array_elements(v_deck) with ordinality as t(tile, ord)
  where ord <> v_indicator_index + 1;

  v_index := 0;
  foreach v_player in array v_players loop
    v_order := v_order + 1;
    v_hand_size := case when v_order = 1 then 15 else 14 end;
    select jsonb_agg(tile order by ord) into v_hand
    from jsonb_array_elements(v_remaining) with ordinality as t(tile, ord)
    where ord > v_index and ord <= v_index + v_hand_size;
    select player_token into v_player_token from public.okey_players where id = v_player;
    insert into public.okey_private_hands(player_id, room_id, player_token, hand)
    values (v_player, p_room_id, v_player_token, coalesce(v_hand,'[]'::jsonb))
    on conflict (player_id) do update set hand = excluded.hand, updated_at = now();
    v_index := v_index + v_hand_size;
  end loop;

  select coalesce(jsonb_agg(tile order by ord), '[]'::jsonb) into v_deck
  from jsonb_array_elements(v_remaining) with ordinality as t(tile, ord)
  where ord > v_index;

  insert into public.okey_games(room_id, current_seat, indicator_tile, okey_tile, remaining_tiles, draw_pile, discarded_tiles, last_discarded_tile, must_draw)
  values (p_room_id, 0, v_indicator, v_okey, jsonb_array_length(v_deck), v_deck, '[]'::jsonb, null, false)
  on conflict (room_id) do update set current_seat = 0, indicator_tile = excluded.indicator_tile,
    okey_tile = excluded.okey_tile, remaining_tiles = excluded.remaining_tiles,
    draw_pile = excluded.draw_pile, discarded_tiles = '[]'::jsonb,
    last_discarded_tile = null, must_draw = false, updated_at = now();

  update public.okey_rooms set status = 'playing', started_at = now() where id = p_room_id;
  return jsonb_build_object('started', true, 'remaining_tiles', jsonb_array_length(v_deck));
end;
$$;

-- Draw from the middle pile.
create or replace function public.draw_okey_tile(p_room_id uuid, p_player_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_player_id uuid; v_seat integer; v_game public.okey_games%rowtype; v_tile jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select id, seat into v_player_id, v_seat from public.okey_players where room_id = p_room_id and player_token = p_player_token;
  select * into v_game from public.okey_games where room_id = p_room_id for update;
  if v_player_id is null or v_game.room_id is null or v_game.current_seat <> v_seat or not v_game.must_draw then raise exception 'Draw is not allowed'; end if;
  v_tile := v_game.draw_pile -> 0;
  if v_tile is null then raise exception 'No tiles remaining'; end if;
  update public.okey_private_hands set hand = hand || jsonb_build_array(v_tile), updated_at = now() where player_id = v_player_id;
  update public.okey_games set draw_pile = (select coalesce(jsonb_agg(tile order by ord), '[]'::jsonb) from jsonb_array_elements(v_game.draw_pile) with ordinality as t(tile,ord) where ord > 1),
    remaining_tiles = greatest(0, remaining_tiles - 1), must_draw = false, updated_at = now() where room_id = p_room_id;
  return v_tile;
end;
$$;

-- Take the most recently discarded tile instead of drawing from the pile.
create or replace function public.take_okey_discard(p_room_id uuid, p_player_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_player_id uuid; v_seat integer; v_game public.okey_games%rowtype; v_tile jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select id, seat into v_player_id, v_seat from public.okey_players where room_id = p_room_id and player_token = p_player_token;
  select * into v_game from public.okey_games where room_id = p_room_id for update;
  if v_player_id is null or v_game.room_id is null or v_game.current_seat <> v_seat or not v_game.must_draw or v_game.last_discarded_tile is null then raise exception 'Taking discard is not allowed'; end if;
  v_tile := v_game.last_discarded_tile;
  update public.okey_private_hands set hand = hand || jsonb_build_array(v_tile), updated_at = now() where player_id = v_player_id;
  update public.okey_games set last_discarded_tile = null, must_draw = false, updated_at = now() where room_id = p_room_id;
  return v_tile;
end;
$$;

-- Discard one tile from the caller's hand and pass the turn to next occupied seat.
create or replace function public.discard_okey_tile(p_room_id uuid, p_player_token text, p_tile_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_player_id uuid; v_seat integer; v_game public.okey_games%rowtype; v_hand jsonb; v_tile jsonb; v_next integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select id, seat into v_player_id, v_seat from public.okey_players where room_id = p_room_id and player_token = p_player_token;
  select * into v_game from public.okey_games where room_id = p_room_id for update;
  if v_player_id is null or v_game.room_id is null or v_game.current_seat <> v_seat or v_game.must_draw then raise exception 'Discard is not allowed'; end if;
  select hand into v_hand from public.okey_private_hands where player_id = v_player_id and player_token = p_player_token for update;
  select tile into v_tile from jsonb_array_elements(coalesce(v_hand,'[]'::jsonb)) as t(tile) where tile->>'id' = p_tile_id limit 1;
  if v_tile is null then raise exception 'Tile not found in your hand'; end if;
  update public.okey_private_hands set hand = (select coalesce(jsonb_agg(tile), '[]'::jsonb) from jsonb_array_elements(v_hand) as t(tile) where tile->>'id' <> p_tile_id), updated_at = now() where player_id = v_player_id;
  select seat into v_next from public.okey_players where room_id = p_room_id and seat is not null and seat > v_seat order by seat limit 1;
  if v_next is null then select min(seat) into v_next from public.okey_players where room_id = p_room_id and seat is not null; end if;
  update public.okey_games set current_seat = v_next,
    discarded_tiles = discarded_tiles || jsonb_build_array(v_tile), last_discarded_tile = v_tile,
    must_draw = true, updated_at = now() where room_id = p_room_id;
  return v_tile;
end;
$$;

-- Reorder a player's own hand; the server verifies that exactly the same tile IDs are sent.
create or replace function public.reorder_okey_hand(p_room_id uuid, p_player_token text, p_tile_ids text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_player_id uuid; v_hand jsonb; v_new_hand jsonb; v_count integer; v_distinct integer;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select id into v_player_id from public.okey_players where room_id = p_room_id and player_token = p_player_token;
  if v_player_id is null then raise exception 'Player not found'; end if;
  select hand into v_hand from public.okey_private_hands where player_id = v_player_id and player_token = p_player_token for update;
  select count(*), count(distinct x) into v_count, v_distinct from unnest(coalesce(p_tile_ids, array[]::text[])) as a(x);
  if v_count <> jsonb_array_length(coalesce(v_hand,'[]'::jsonb)) or v_count <> v_distinct then raise exception 'Invalid hand order'; end if;
  select jsonb_agg(found.tile order by wanted.ord) into v_new_hand
  from unnest(p_tile_ids) with ordinality as wanted(id,ord)
  join lateral (select tile from jsonb_array_elements(v_hand) as e(tile) where tile->>'id' = wanted.id limit 1) found on true;
  if jsonb_array_length(coalesce(v_new_hand,'[]'::jsonb)) <> v_count then raise exception 'Invalid hand order'; end if;
  update public.okey_private_hands set hand = v_new_hand, updated_at = now() where player_id = v_player_id;
  return v_new_hand;
end;
$$;

-- -----------------------------------------------------------------------------
-- Function permissions: anonymous Auth users are JWT role authenticated.
-- The plain anon API role is intentionally not allowed to call gameplay RPCs.
-- -----------------------------------------------------------------------------
revoke all on function public.join_okey_room(text,text,text,text) from public, anon;
revoke all on function public.get_okey_player(uuid,text) from public, anon;
revoke all on function public.leave_okey_room(uuid,text) from public, anon;
revoke all on function public.start_okey_game(uuid,text) from public, anon;
revoke all on function public.draw_okey_tile(uuid,text) from public, anon;
revoke all on function public.take_okey_discard(uuid,text) from public, anon;
revoke all on function public.discard_okey_tile(uuid,text,text) from public, anon;
revoke all on function public.reorder_okey_hand(uuid,text,text[]) from public, anon;
grant execute on function public.join_okey_room(text,text,text,text) to authenticated;
grant execute on function public.get_okey_player(uuid,text) to authenticated;
grant execute on function public.leave_okey_room(uuid,text) to authenticated;
grant execute on function public.start_okey_game(uuid,text) to authenticated;
grant execute on function public.draw_okey_tile(uuid,text) to authenticated;
grant execute on function public.take_okey_discard(uuid,text) to authenticated;
grant execute on function public.discard_okey_tile(uuid,text,text) to authenticated;
grant execute on function public.reorder_okey_hand(uuid,text,text[]) to authenticated;

-- Add realtime tables without failing if they are already published.
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'okey_rooms') then
    alter publication supabase_realtime add table public.okey_rooms;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'okey_players') then
    alter publication supabase_realtime add table public.okey_players;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'okey_games') then
    alter publication supabase_realtime add table public.okey_games;
  end if;
end $$;

notify pgrst, 'reload schema';
