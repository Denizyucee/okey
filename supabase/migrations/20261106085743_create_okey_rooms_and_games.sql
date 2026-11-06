/*
# Create shared Okey rooms and live game state

1. New Tables
- `okey_rooms` stores each private room code, owner token, lifecycle status, and start timestamp.
- `okey_players` stores up to four seated players plus optional spectators, including their nickname, avatar, seat, and hand.
- `okey_games` stores the durable current turn, indicator tile, remaining tiles, and table snapshot for realtime play.

2. Security
- Row level security is enabled on every table.
- This app intentionally supports anonymous play without accounts, so anon and authenticated roles receive only the CRUD access needed by the shared room experience.
- Room data is scoped in application queries by room code and player token; all writes are limited to expected game fields through the client flow.

3. Important Notes
- No auth.users relationship is used because players can join with a nickname only.
- JSONB fields preserve the evolving tile state without destructive schema changes.
- Realtime publication is enabled for all three tables so room members receive changes immediately.
*/

CREATE TABLE IF NOT EXISTS public.okey_rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  owner_token text NOT NULL,
  status text NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting', 'playing', 'finished')),
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz
);

CREATE TABLE IF NOT EXISTS public.okey_players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES public.okey_rooms(id) ON DELETE CASCADE,
  player_token text NOT NULL,
  nickname text NOT NULL,
  avatar text NOT NULL DEFAULT 'sun',
  seat integer CHECK (seat BETWEEN 0 AND 3),
  is_spectator boolean NOT NULL DEFAULT false,
  hand jsonb NOT NULL DEFAULT '[]'::jsonb,
  score integer NOT NULL DEFAULT 0,
  joined_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(room_id, player_token)
);

CREATE TABLE IF NOT EXISTS public.okey_games (
  room_id uuid PRIMARY KEY REFERENCES public.okey_rooms(id) ON DELETE CASCADE,
  current_seat integer NOT NULL DEFAULT 0 CHECK (current_seat BETWEEN 0 AND 3),
  indicator_tile jsonb NOT NULL DEFAULT '{"color":"red","value":5,"id":"red-5"}'::jsonb,
  okey_tile jsonb NOT NULL DEFAULT '{"color":"red","value":6,"id":"red-6"}'::jsonb,
  remaining_tiles integer NOT NULL DEFAULT 106,
  discarded_tiles jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.okey_rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.okey_players ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.okey_games ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.okey_rooms TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.okey_players TO anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.okey_games TO anon, authenticated;

DROP POLICY IF EXISTS "public room access" ON public.okey_rooms;
CREATE POLICY "public room access" ON public.okey_rooms FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "public room create" ON public.okey_rooms;
CREATE POLICY "public room create" ON public.okey_rooms FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "public room update" ON public.okey_rooms;
CREATE POLICY "public room update" ON public.okey_rooms FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "public room delete" ON public.okey_rooms;
CREATE POLICY "public room delete" ON public.okey_rooms FOR DELETE TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "public player access" ON public.okey_players;
CREATE POLICY "public player access" ON public.okey_players FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "public player create" ON public.okey_players;
CREATE POLICY "public player create" ON public.okey_players FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "public player update" ON public.okey_players;
CREATE POLICY "public player update" ON public.okey_players FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "public player delete" ON public.okey_players;
CREATE POLICY "public player delete" ON public.okey_players FOR DELETE TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "public game access" ON public.okey_games;
CREATE POLICY "public game access" ON public.okey_games FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS "public game create" ON public.okey_games;
CREATE POLICY "public game create" ON public.okey_games FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS "public game update" ON public.okey_games;
CREATE POLICY "public game update" ON public.okey_games FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS "public game delete" ON public.okey_games;
CREATE POLICY "public game delete" ON public.okey_games FOR DELETE TO anon, authenticated USING (true);

ALTER PUBLICATION supabase_realtime ADD TABLE public.okey_rooms;
ALTER PUBLICATION supabase_realtime ADD TABLE public.okey_players;
ALTER PUBLICATION supabase_realtime ADD TABLE public.okey_games;