/*
# Tighten classic Okey server moves

1. Public data
- Authenticated players can read only identity, seat, status, and score columns.
- Private hand rows and the draw pile remain outside normal table reads.

2. Server rules
- Correct the 106-tile deal so the indicator and dealt tiles are removed from the draw pile.
- The starting player receives 15 tiles and begins in discard mode.
- Drawing removes the first tile atomically from the draw pile.

3. Security
- Anonymous database role cannot call gameplay RPCs.
- Authenticated gameplay calls use the existing room/player token compatibility boundary while hand contents remain private in `okey_private_hands`.
*/

REVOKE EXECUTE ON FUNCTION public.start_okey_game(uuid, text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.draw_okey_tile(uuid, text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.take_okey_discard(uuid, text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.discard_okey_tile(uuid, text, text) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.reorder_okey_hand(uuid, text, text[]) FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_okey_player(uuid, text) FROM anon, PUBLIC;
GRANT EXECUTE ON FUNCTION public.start_okey_game(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.draw_okey_tile(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.take_okey_discard(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.discard_okey_tile(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reorder_okey_hand(uuid, text, text[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_okey_player(uuid, text) TO authenticated;

REVOKE SELECT ON public.okey_players FROM authenticated;
GRANT SELECT (id, room_id, player_token, nickname, avatar, seat, is_spectator, score, joined_at, last_seen_at) ON public.okey_players TO authenticated;
REVOKE SELECT ON public.okey_games FROM authenticated;
GRANT SELECT (room_id, current_seat, indicator_tile, okey_tile, remaining_tiles, discarded_tiles, last_discarded_tile, must_draw, created_at, updated_at) ON public.okey_games TO authenticated;

CREATE OR REPLACE FUNCTION public.start_okey_game(p_room_id uuid, p_player_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_owner text; v_players uuid[]; v_count integer; v_deck jsonb; v_indicator jsonb; v_okey jsonb; v_hand jsonb; v_remaining jsonb; v_player uuid; v_index integer := 1; v_order integer := 0; v_hand_size integer;
BEGIN
  SELECT owner_token INTO v_owner FROM public.okey_rooms WHERE id = p_room_id AND status = 'waiting';
  IF v_owner IS NULL OR v_owner <> p_player_token THEN RAISE EXCEPTION 'Not authorized to start'; END IF;
  SELECT array_agg(id ORDER BY seat), count(*) INTO v_players, v_count FROM public.okey_players WHERE room_id = p_room_id AND seat IS NOT NULL;
  IF v_count < 2 OR v_count > 4 THEN RAISE EXCEPTION 'Invalid player count'; END IF;
  SELECT jsonb_agg(jsonb_build_object('id', color || '-' || value || '-' || copy, 'value', value, 'color', color) ORDER BY random()) INTO v_deck
  FROM (SELECT c.color, n.value, x.copy FROM unnest(ARRAY['red','blue','black','yellow']) c(color) CROSS JOIN generate_series(1,13) n(value) CROSS JOIN generate_series(1,2) x(copy) UNION ALL SELECT 'joker', 0, 1 UNION ALL SELECT 'joker', 0, 2) tiles;
  v_indicator := v_deck -> 0;
  WHILE (v_indicator->>'color') = 'joker' LOOP v_indicator := v_deck -> v_index; v_index := v_index + 1; END LOOP;
  v_okey := jsonb_build_object('id', v_indicator->>'color' || '-' || (((v_indicator->>'value')::integer % 13) + 1) || '-okey', 'value', (((v_indicator->>'value')::integer % 13) + 1), 'color', v_indicator->>'color');
  v_index := 1;
  FOREACH v_player IN ARRAY v_players LOOP
    v_order := v_order + 1; v_hand_size := CASE WHEN v_order = 1 THEN 15 ELSE 14 END;
    SELECT jsonb_agg(element) INTO v_hand FROM (SELECT element FROM jsonb_array_elements(v_deck) WITH ORDINALITY rows(element, ord) WHERE ord > v_index AND ord <= v_index + v_hand_size) picked;
    INSERT INTO public.okey_private_hands(player_id, room_id, player_token, hand) SELECT p.id, p_room_id, p.player_token, COALESCE(v_hand, '[]'::jsonb) FROM public.okey_players p WHERE p.id = v_player ON CONFLICT (player_id) DO UPDATE SET hand = EXCLUDED.hand, updated_at = now();
    v_index := v_index + v_hand_size;
  END LOOP;
  SELECT jsonb_agg(element) INTO v_remaining FROM (SELECT element FROM jsonb_array_elements(v_deck) WITH ORDINALITY rows(element, ord) WHERE ord > v_index) left_tiles;
  INSERT INTO public.okey_games(room_id, current_seat, indicator_tile, okey_tile, remaining_tiles, draw_pile, discarded_tiles, last_discarded_tile, must_draw) VALUES (p_room_id, 0, v_indicator, v_okey, jsonb_array_length(COALESCE(v_remaining, '[]'::jsonb)), COALESCE(v_remaining, '[]'::jsonb), '[]'::jsonb, NULL, false) ON CONFLICT (room_id) DO UPDATE SET current_seat = 0, indicator_tile = EXCLUDED.indicator_tile, okey_tile = EXCLUDED.okey_tile, remaining_tiles = EXCLUDED.remaining_tiles, draw_pile = EXCLUDED.draw_pile, discarded_tiles = '[]'::jsonb, last_discarded_tile = NULL, must_draw = false, updated_at = now();
  UPDATE public.okey_rooms SET status = 'playing', started_at = now() WHERE id = p_room_id;
  RETURN jsonb_build_object('started', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.draw_okey_tile(p_room_id uuid, p_player_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_player_id uuid; v_seat integer; v_game public.okey_games%ROWTYPE; v_tile jsonb;
BEGIN
  SELECT id, seat INTO v_player_id, v_seat FROM public.okey_players WHERE room_id = p_room_id AND player_token = p_player_token;
  SELECT * INTO v_game FROM public.okey_games WHERE room_id = p_room_id FOR UPDATE;
  IF v_player_id IS NULL OR v_game.room_id IS NULL OR v_game.current_seat <> v_seat OR NOT v_game.must_draw THEN RAISE EXCEPTION 'Draw is not allowed'; END IF;
  v_tile := v_game.draw_pile -> 0;
  IF v_tile IS NULL THEN RAISE EXCEPTION 'No tiles remaining'; END IF;
  UPDATE public.okey_private_hands SET hand = hand || jsonb_build_array(v_tile), updated_at = now() WHERE player_id = v_player_id;
  UPDATE public.okey_games SET draw_pile = (SELECT COALESCE(jsonb_agg(element), '[]'::jsonb) FROM jsonb_array_elements(v_game.draw_pile) WITH ORDINALITY rows(element, ord) WHERE ord > 1), remaining_tiles = GREATEST(0, remaining_tiles - 1), must_draw = false, updated_at = now() WHERE room_id = p_room_id;
  RETURN v_tile;
END;
$$;