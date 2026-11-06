/*
# Add secure room joining

1. New function
- `join_okey_room` assigns the first available seat, creates the public player row, and creates the matching private hand row atomically.

2. Security
- Only authenticated anonymous sessions can call it.
- The browser cannot choose a seat or write a hand directly.
- Existing public nickname and avatar editing remains supported through the returned player row.
*/

CREATE OR REPLACE FUNCTION public.join_okey_room(p_code text, p_player_token text, p_nickname text, p_avatar text)
RETURNS public.okey_players LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_room public.okey_rooms; v_player public.okey_players; v_seat integer;
BEGIN
  IF auth.uid() IS NULL OR length(trim(p_nickname)) < 1 OR length(trim(p_nickname)) > 18 THEN RAISE EXCEPTION 'Invalid player'; END IF;
  SELECT * INTO v_room FROM public.okey_rooms WHERE code = upper(trim(p_code)) FOR UPDATE;
  IF v_room.id IS NULL THEN RAISE EXCEPTION 'Room unavailable'; END IF;
  SELECT * INTO v_player FROM public.okey_players WHERE room_id = v_room.id AND player_token = p_player_token;
  IF v_player.id IS NOT NULL THEN
    UPDATE public.okey_players SET nickname = trim(p_nickname), avatar = p_avatar, last_seen_at = now() WHERE id = v_player.id RETURNING * INTO v_player;
    RETURN v_player;
  END IF;
  SELECT seat INTO v_seat FROM generate_series(0, 3) available(seat) WHERE NOT EXISTS (SELECT 1 FROM public.okey_players p WHERE p.room_id = v_room.id AND p.seat = available.seat) LIMIT 1;
  IF v_seat IS NULL AND v_room.status = 'waiting' THEN RAISE EXCEPTION 'Room full'; END IF;
  INSERT INTO public.okey_players(room_id, player_token, nickname, avatar, seat, is_spectator) VALUES (v_room.id, p_player_token, trim(p_nickname), p_avatar, v_seat, v_seat IS NULL) RETURNING * INTO v_player;
  INSERT INTO public.okey_private_hands(player_id, room_id, player_token, hand) VALUES (v_player.id, v_room.id, p_player_token, '[]'::jsonb);
  RETURN v_player;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.join_okey_room(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_okey_room(text, text, text, text) TO authenticated;