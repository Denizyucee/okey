/*
# Restore anonymous Okey room access

1. Problem fixed
- Players can enter without an account, as requested by the product flow.
- Room creation now completes the follow-up player join instead of stopping after the room insert.

2. Access
- Anonymous and authenticated roles can read only public room/player/game metadata.
- Anonymous gameplay functions still never expose the private hand table or the draw pile.
- The server functions continue validating room membership, turn order, and tile ownership before changing a hand.
*/

GRANT SELECT (id, room_id, player_token, nickname, avatar, seat, is_spectator, score, joined_at, last_seen_at) ON public.okey_players TO anon, authenticated;
GRANT SELECT (room_id, current_seat, indicator_tile, okey_tile, remaining_tiles, discarded_tiles, last_discarded_tile, must_draw, created_at, updated_at) ON public.okey_games TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.join_okey_room(text, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_okey_player(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.start_okey_game(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.draw_okey_tile(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.take_okey_discard(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.discard_okey_tile(uuid, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reorder_okey_hand(uuid, text, text[]) TO anon, authenticated;