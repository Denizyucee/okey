import { useEffect, useMemo, useState } from 'react';
import { DndContext, DragEndEvent, useDraggable, useDroppable } from '@dnd-kit/core';
import { ArrowLeft, Check, ChevronRight, Copy, Crown, Dice5, Grid2X2, LogOut, MoreHorizontal, Play, Plus, Radio, Send, Settings, Sparkles, Users, Volume2, X, Zap } from 'lucide-react';
import { supabase } from '@/lib/supabase';

type TileColor = 'red' | 'blue' | 'black' | 'yellow' | 'joker';
type Tile = { id: string; value: number | string; color: TileColor };
type Player = { id: string; room_id: string; player_token: string; nickname: string; avatar: string; seat: number | null; is_spectator: boolean; hand?: Tile[]; score: number };
type Room = { id: string; code: string; owner_token: string; status: 'waiting' | 'playing' | 'finished' };
type Game = { room_id: string; current_seat: number; indicator_tile: Tile; okey_tile: Tile; remaining_tiles: number; discarded_tiles: Tile[]; last_discarded_tile: Tile | null; must_draw: boolean };

const avatars = ['sun', 'moon', 'leaf', 'flame', 'wave', 'star'];
const avatarColors: Record<string, string> = { sun: '#f59e0b', moon: '#6d8edb', leaf: '#65a30d', flame: '#ef744a', wave: '#299bb1', star: '#cf6eac' };
const avatarSymbols: Record<string, string> = { sun: '☼', moon: '◐', leaf: '⌁', flame: '✦', wave: '≈', star: '✶' };
const newToken = () => `${Date.now()}-${Math.random().toString(36).slice(2, 9)}`;
const getToken = () => localStorage.getItem('okey-player-token') ?? newToken();

function Avatar({ name, size = 'md', active = false }: { name: string; size?: 'sm' | 'md' | 'lg'; active?: boolean }) {
  return <div className={`avatar avatar-${size} ${active ? 'avatar-active' : ''}`} style={{ background: `linear-gradient(145deg, ${avatarColors[name] ?? '#799194'}, #172b2a)` }}><span>{avatarSymbols[name] ?? '✶'}</span></div>;
}

function TileView({ tile, draggable = false, small = false }: { tile: Tile; draggable?: boolean; small?: boolean }) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({ id: tile.id, disabled: !draggable });
  const color = tile.color === 'joker' ? 'joker' : tile.color;
  return <div ref={setNodeRef} style={{ transform: transform ? `translate3d(${transform.x}px, ${transform.y}px, 0)` : undefined }} {...listeners} {...attributes} className={`tile tile-${color} ${small ? 'tile-small' : ''} ${draggable ? 'tile-draggable' : ''} ${isDragging ? 'tile-dragging' : ''}`}><span>{tile.value}</span>{tile.color !== 'joker' && <i />}</div>;
}

function DropZone({ children, className = '' }: { children: React.ReactNode; className?: string }) {
  const { setNodeRef, isOver } = useDroppable({ id: 'discard-zone' });
  return <div ref={setNodeRef} className={`${className} ${isOver ? 'drop-active' : ''}`}>{children}</div>;
}

function App() {
  const [screen, setScreen] = useState<'home' | 'lobby' | 'game'>('home');
  const [nickname, setNickname] = useState('');
  const [avatar, setAvatar] = useState('sun');
  const [roomCode, setRoomCode] = useState('');
  const [room, setRoom] = useState<Room | null>(null);
  const [players, setPlayers] = useState<Player[]>([]);
  const [game, setGame] = useState<Game | null>(null);
  const [myPlayer, setMyPlayer] = useState<Player | null>(null);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState(false);
  const [authReady, setAuthReady] = useState(false);
  const [authError, setAuthError] = useState('');
  const token = useMemo(getToken, []);

  useEffect(() => { localStorage.setItem('okey-player-token', token); }, [token]);

  useEffect(() => {
    let active = true;
    const initializeSession = async () => {
      try {
        const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
        if (sessionError) throw sessionError;

        let session = sessionData.session;
        if (!session) {
          const { data, error: signInError } = await supabase.auth.signInAnonymously();
          if (signInError) throw signInError;
          session = data.session;
        }
        if (!session?.user?.id) throw new Error('Misafir oturumu oluşturulamadı.');
        if (active) {
          setAuthError('');
          setAuthReady(true);
        }
      } catch (cause) {
        const detail = cause instanceof Error ? cause.message : 'Bilinmeyen oturum hatası';
        if (active) {
          setAuthError(`Misafir girişi başarısız: ${detail}. Supabase Dashboard > Authentication > Providers bölümünden Anonymous Sign-Ins özelliğini etkinleştir.`);
          setAuthReady(true);
        }
      }
    };
    void initializeSession();
    return () => { active = false; };
  }, []);

  useEffect(() => {
    const inviteCode = window.location.pathname.match(/room\/([A-Z0-9-]+)/i)?.[1];
    if (inviteCode) setRoomCode(inviteCode.toUpperCase());
  }, []);

  useEffect(() => {
    if (!room || !authReady) return;
    const load = async () => {
      const [{ data: playerRows }, { data: gameRow }, { data: ownPlayer }] = await Promise.all([
        supabase.from('okey_players').select('id, room_id, player_token, nickname, avatar, seat, is_spectator, score, joined_at, last_seen_at').eq('room_id', room.id).order('seat'),
        supabase.from('okey_games').select('room_id, current_seat, indicator_tile, okey_tile, remaining_tiles, discarded_tiles, last_discarded_tile, must_draw').eq('room_id', room.id).maybeSingle(),
        supabase.rpc('get_okey_player', { p_room_id: room.id, p_player_token: token }).maybeSingle(),
      ]);
      if (playerRows) setPlayers(playerRows as Player[]);
      if (ownPlayer) setMyPlayer(ownPlayer as Player);
      if (gameRow) setGame(gameRow as Game);
    };
    void load();
    const channel = supabase.channel(`room-${room.id}`).on('postgres_changes', { event: '*', schema: 'public', table: 'okey_players', filter: `room_id=eq.${room.id}` }, (payload) => {
      if (payload.eventType === 'DELETE') setPlayers((current) => current.filter((p) => p.id !== payload.old.id));
      else setPlayers((current) => { const next = current.filter((p) => p.id !== (payload.new as Player).id); return [...next, payload.new as Player].sort((a, b) => (a.seat ?? 9) - (b.seat ?? 9)); });
        if ((payload.new as Player).player_token === token) void supabase.rpc('get_okey_player', { p_room_id: room.id, p_player_token: token }).then(({ data }) => { if (data) setMyPlayer(data as Player); });
    }).on('postgres_changes', { event: '*', schema: 'public', table: 'okey_rooms', filter: `id=eq.${room.id}` }, (payload) => { if (payload.new) { const nextRoom = payload.new as Room; setRoom(nextRoom); if (nextRoom.status === 'playing') setScreen('game'); } }).on('postgres_changes', { event: '*', schema: 'public', table: 'okey_games', filter: `room_id=eq.${room.id}` }, (payload) => { if (payload.new) setGame(payload.new as Game); }).subscribe();
    return () => { void supabase.removeChannel(channel); };
  }, [room, token, authReady]);

  const createRoom = async () => {
    if (!nickname.trim()) { setError('Oyuna başlamadan önce bir takma ad seç.'); return; }
    setError('');
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError || !sessionData.session?.user?.id) {
      setError(authError || 'Geçerli misafir oturumu bulunamadı. Sayfayı yenile veya Supabase Anonymous Sign-Ins ayarını kontrol et.');
      return;
    }
    const code = `OKY-${Math.floor(1000 + Math.random() * 9000)}`;
    const { data, error: roomError } = await supabase.from('okey_rooms').insert({ code, owner_token: token }).select('id, code, owner_token, status').single();
    if (roomError || !data) { setError(`Oda oluşturulamadı: ${roomError?.message ?? 'Oda kaydı dönmedi.'}`); return; }
    await joinRoom(data as Room);
  };

  const joinRoom = async (knownRoom?: Room) => {
    if (!nickname.trim()) { setError('Oyuna başlamadan önce bir takma ad seç.'); return; }
    setError('');
    const { data: sessionData, error: sessionError } = await supabase.auth.getSession();
    if (sessionError || !sessionData.session?.user?.id) {
      setError(authError || 'Geçerli misafir oturumu yok. Supabase Anonymous Sign-Ins ayarını kontrol et.');
      return;
    }
    let target = knownRoom;
    if (!target) {
      const { data } = await supabase.from('okey_rooms').select('*').eq('code', roomCode.trim().toUpperCase()).maybeSingle();
      if (!data) { setError('Bu kodla eşleşen bir oda bulunamadı.'); return; }
      target = data as Room;
    }
    const { data: joinedPlayer, error: playerError } = await supabase.rpc('join_okey_room', { p_code: target.code, p_player_token: token, p_nickname: nickname.trim(), p_avatar: avatar });
    if (playerError) {
      const detail = playerError.message || playerError.details || playerError.hint || 'Bilinmeyen veritabanı hatası';
      setError(`Odaya katılınamadı: ${detail}`);
      return;
    }
    if (!joinedPlayer) { setError('Odaya katılma işlemi yanıt döndürmedi. Supabase SQL migration dosyalarını kontrol et.'); return; }
    setMyPlayer(joinedPlayer as Player);
    setRoom(target); setScreen(target.status === 'playing' ? 'game' : 'lobby');
  };

  const startGame = async () => {
    if (!room || room.owner_token !== token || players.length < 2) return;
    const { error: startError } = await supabase.rpc('start_okey_game', { p_room_id: room.id, p_player_token: token });
    if (startError) { setError('Oyun başlatılamadı.'); return; }
  };

  const leaveRoom = async () => { if (room && myPlayer) await supabase.from('okey_players').delete().eq('id', myPlayer.id); setRoom(null); setPlayers([]); setGame(null); setScreen('home'); };
  const copyInvite = async () => { if (!room) return; await navigator.clipboard?.writeText(`${window.location.origin}/room/${room.code}`); setCopied(true); window.setTimeout(() => setCopied(false), 1600); };

  if (!authReady) return <main className="home-shell"><div className="loading-screen">Masaya bağlanılıyor...</div></main>;
  if (screen === 'game' && room && game) return <GameTable room={room} game={game} players={players} myPlayer={myPlayer} onLeave={leaveRoom} />;
  if (screen === 'lobby' && room) return <Lobby room={room} players={players} token={token} copied={copied} onCopy={copyInvite} onStart={startGame} onLeave={leaveRoom} />;
  return <Home nickname={nickname} setNickname={setNickname} avatar={avatar} setAvatar={setAvatar} roomCode={roomCode} setRoomCode={setRoomCode} error={error || authError} onCreate={createRoom} onJoin={() => void joinRoom()} />;
}

function Home({ nickname, setNickname, avatar, setAvatar, roomCode, setRoomCode, error, onCreate, onJoin }: { nickname: string; setNickname: (value: string) => void; avatar: string; setAvatar: (value: string) => void; roomCode: string; setRoomCode: (value: string) => void; error: string; onCreate: () => void; onJoin: () => void }) {
  return <main className="home-shell"><div className="ambient ambient-one" /><div className="ambient ambient-two" /><header className="topbar"><div className="brand-mark"><span className="brand-gem">◆</span><span>OKY</span></div><div className="top-status"><span className="live-dot" /> <span>Canlı oyun platformu</span><button className="icon-button"><Settings size={17} /></button></div></header><section className="home-content"><div className="hero-copy"><div className="eyebrow"><Sparkles size={14} /> Klasik oyunun yeni adresi</div><h1>Arkadaşlarınla<br /><em>masaya otur.</em></h1><p>Gerçek zamanlı, hızlı ve keyifli. Odanı kur, taşlarını diz, oyunun tadını çıkar.</p><div className="hero-stats"><span><strong>4</strong> kişilik odalar</span><span><strong>24/7</strong> canlı oyun</span></div></div><div className="entry-card"><div className="card-heading"><div><span className="eyebrow">Oyuna katıl</span><h2>Masadaki yerini al</h2></div><div className="dice-icon"><Dice5 size={22} /></div></div><label className="field-label">TAKMA ADIN</label><div className="name-field"><Avatar name={avatar} size="sm" /><input value={nickname} onChange={(event) => setNickname(event.target.value)} maxLength={18} placeholder="Nasıl çağırılmak istersin?" /><Check size={17} className={nickname ? 'field-check visible' : 'field-check'} /></div><label className="field-label">AVATARINI SEÇ</label><div className="avatar-picker">{avatars.map((item) => <button type="button" key={item} onClick={() => setAvatar(item)} className={avatar === item ? 'selected' : ''}><Avatar name={item} size="sm" /></button>)}</div><button className="primary-button" onClick={onCreate}><Plus size={18} /> Yeni oda oluştur <ChevronRight size={17} /></button><div className="or-divider"><span /> veya <span /></div><div className="join-row"><input value={roomCode} onChange={(event) => setRoomCode(event.target.value.toUpperCase())} placeholder="OKY-0000" /><button className="secondary-button" onClick={onJoin}>Odaya katıl <ArrowLeft size={16} /></button></div>{error && <div className="form-error"><X size={15} /> {error}</div>}<p className="no-account"><Zap size={13} /> Kayıt yok, şifre yok. Sadece adını seç ve oyna.</p></div></section><footer className="home-footer"><span>© 2026 OKY</span><span className="footer-links">Güvenli oyun <span /> Her cihazda</span></footer></main>;
}

function Lobby({ room, players, token, copied, onCopy, onStart, onLeave }: { room: Room; players: Player[]; token: string; copied: boolean; onCopy: () => void; onStart: () => void; onLeave: () => void }) {
  const seats = [0, 1, 2, 3].map((seat) => players.find((p) => p.seat === seat));
  return <main className="lobby-shell"><header className="topbar"><button className="back-link" onClick={onLeave}><ArrowLeft size={16} /> Ana sayfa</button><div className="brand-mark"><span className="brand-gem">◆</span><span>OKY</span></div><div className="top-status"><span className="live-dot" /> Bekleme salonu</div></header><section className="lobby-content"><div className="lobby-intro"><div className="eyebrow"><Radio size={14} /> Oda hazır</div><h1>Oyuncularını<br /><em>bekliyorsun.</em></h1><p>Arkadaşlarını davet et, herkes hazır olduğunda oyunu başlat.</p><div className="room-code-block"><span>ODA KODU</span><strong>{room.code}</strong><button onClick={onCopy}>{copied ? <Check size={15} /> : <Copy size={15} />} {copied ? 'Kopyalandı' : 'Kodu kopyala'}</button></div></div><div className="lobby-panel"><div className="panel-top"><div><span className="eyebrow">Bekleme salonu</span><h2><Users size={19} /> {players.length} / 4 oyuncu</h2></div><div className="room-live"><span className="live-dot" /> Canlı</div></div><div className="seat-grid">{seats.map((player, index) => <div className={`seat-card ${player ? 'filled' : ''}`} key={index}>{player ? <><div className="seat-number">0{index + 1}</div><Avatar name={player.avatar} size="lg" active={player.player_token === token} /><div className="seat-name">{player.nickname} {player.player_token === room.owner_token && <Crown size={13} />}</div><span className="seat-label">{player.player_token === room.owner_token ? 'Oda sahibi' : 'Oyuncu'}</span>{player.player_token === token && <span className="you-tag">SEN</span>}</> : <><div className="empty-seat"><Plus size={21} /></div><span className="seat-label">Arkadaşını bekliyor</span></>}</div>)}</div><button className="primary-button start-button" onClick={onStart} disabled={room.owner_token !== token || players.length < 2}><Play size={17} /> {players.length < 2 ? 'En az 2 oyuncu gerekli' : room.owner_token === token ? 'Oyunu başlat' : 'Oda sahibini bekle'} <ChevronRight size={17} /></button><button className="invite-button" onClick={onCopy}><Send size={16} /> Davet bağlantısını paylaş</button><p className="lobby-note"><Sparkles size={13} /> Oyun başladıktan sonra izleyici olarak katılabilirsin.</p></div></section></main>;
}

function GameTable({ room, game, players, myPlayer, onLeave }: { room: Room; game: Game; players: Player[]; myPlayer: Player | null; onLeave: () => void }) {
  const [hand, setHand] = useState<Tile[]>(myPlayer?.hand ?? []);
  const [message, setMessage] = useState('Taşını sürükleyip ortaya bırak');
  const [selected, setSelected] = useState<string | null>(null);
  useEffect(() => { if (myPlayer?.hand) setHand(myPlayer.hand); }, [myPlayer]);
  const top = players.find((p) => p.seat === 0);
  const left = players.find((p) => p.seat === 1);
  const right = players.find((p) => p.seat === 2);
  const currentPlayer = players.find((p) => p.seat === game.current_seat);
  const isMyTurn = myPlayer?.seat === game.current_seat;
  const refreshHand = async () => {
    if (!myPlayer) return;
    const { data } = await supabase.rpc('get_okey_player', { p_room_id: room.id, p_player_token: myPlayer.player_token }).maybeSingle();
    if (data) setHand((data as Player).hand ?? []);
  };
  const handleDrop = async (event: DragEndEvent) => {
    if (event.over?.id !== 'discard-zone' || !event.active.id || !isMyTurn || game.must_draw) {
      if (!isMyTurn) setMessage('Sıra sende değil');
      else if (game.must_draw) setMessage('Önce ortadan taş çek veya atılan taşı al');
      return;
    }
    const { error: moveError } = await supabase.rpc('discard_okey_tile', { p_room_id: room.id, p_player_token: myPlayer?.player_token, p_tile_id: String(event.active.id) });
    if (moveError) { setMessage('Bu taş şu anda atılamıyor'); return; }
    setMessage('Taş ortaya bırakıldı');
    await refreshHand();
  };
  const drawTile = async () => {
    if (!isMyTurn || !myPlayer || !game.must_draw) { setMessage('Şu anda taş çekemezsin'); return; }
    const { error: drawError } = await supabase.rpc('draw_okey_tile', { p_room_id: room.id, p_player_token: myPlayer.player_token });
    if (drawError) { setMessage('Taş çekilemedi'); return; }
    setMessage('Yeni taşını çektin');
    await refreshHand();
  };
  const reorderHand = async (tileId: string) => {
    if (!selected || selected === tileId || !myPlayer) { setSelected(tileId); return; }
    const from = hand.findIndex((tile) => tile.id === selected);
    const to = hand.findIndex((tile) => tile.id === tileId);
    if (from < 0 || to < 0) return;
    const next = [...hand];
    [next[from], next[to]] = [next[to], next[from]];
    setHand(next);
    setSelected(null);
    await supabase.rpc('reorder_okey_hand', { p_room_id: room.id, p_player_token: myPlayer.player_token, p_tile_ids: next.map((tile) => tile.id) });
  };
  const takeDiscard = async () => {
    if (!isMyTurn || !myPlayer || !game.must_draw || !game.last_discarded_tile) { setMessage('Atılan taşı şu anda alamazsın'); return; }
    const { error: takeError } = await supabase.rpc('take_okey_discard', { p_room_id: room.id, p_player_token: myPlayer.player_token });
    if (takeError) { setMessage('Atılan taş alınamadı'); return; }
    setMessage('Atılan taşı aldın');
    await refreshHand();
  };
  return <main className="game-shell"><header className="game-topbar"><div className="brand-mark"><span className="brand-gem">◆</span><span>OKY</span></div><div className="game-room"><span>ODA</span><strong>{room.code}</strong><i /> <span><Radio size={13} /> CANLI</span></div><div className="game-actions"><button><Volume2 size={17} /></button><button><MoreHorizontal size={18} /></button><button onClick={onLeave}><LogOut size={16} /></button></div></header><div className="game-layout"><aside className="game-side"><div className="side-label">OYUN BİLGİSİ</div><div className="info-card"><span>KALAN TAŞ</span><strong>{game.remaining_tiles}</strong><div className="progress"><i style={{ width: `${Math.max(12, (game.remaining_tiles / 106) * 100)}%` }} /></div></div><div className="info-card"><span>GÖSTERGE</span><div className="indicator-wrap"><TileView tile={game.indicator_tile} small /><div className="okey-badge">OKEY<br /><b>{String(game.okey_tile.value)}</b></div></div></div><div className="side-chat"><div className="side-label">MASA SOHBETİ</div><div className="chat-bubble"><span>Alja</span> Hazır mısınız?</div><div className="chat-input"><input placeholder="Bir şey yaz..." /><Send size={14} /></div></div></aside><section className="table-stage"><div className="table-felt"><div className="felt-glow" /><div className="opponent opponent-top">{top && <PlayerBadge player={top} active={currentPlayer?.id === top.id} />}</div><div className="opponent opponent-left">{left && <PlayerBadge player={left} active={currentPlayer?.id === left.id} vertical />}</div><div className="opponent opponent-right">{right && <PlayerBadge player={right} active={currentPlayer?.id === right.id} vertical />}</div><div className="center-table"><div className="turn-label"><span className="live-dot" /> {currentPlayer?.nickname ?? 'Oyuncu'} oynuyor</div><div className="center-tiles"><TileView tile={game.indicator_tile} /><div className="center-arrow"><ChevronRight size={15} /></div><TileView tile={game.okey_tile} /><span className="okey-caption">OKEY TAŞI</span></div><DropZone className="discard-zone">{game.last_discarded_tile ? <TileView tile={game.last_discarded_tile} small /> : <span><Grid2X2 size={16} /> Taşını buraya bırak</span>}</DropZone></div><div className="my-player"><div className={`my-player-tag ${isMyTurn ? 'turn' : ''}`}><Avatar name={myPlayer?.avatar ?? 'sun'} size="md" active={isMyTurn} /><div><strong>{myPlayer?.nickname ?? 'Sen'}</strong><span>{isMyTurn ? 'Sıra sende' : 'Sıranı bekle'}</span></div><b>{myPlayer?.score ?? 0}</b></div><DndContext onDragEnd={(event) => void handleDrop(event)}><div className="wood-rack"><div className="rack-inset">{hand.map((tile) => <button key={tile.id} onClick={() => void reorderHand(tile.id)} className={selected === tile.id ? 'tile-selected' : ''}><TileView tile={tile} draggable /></button>)}</div></div></DndContext><div className="hand-actions"><span className="game-message">{message}</span><button onClick={drawTile} className="draw-button"><Plus size={15} /> Taş çek</button><button onClick={takeDiscard} className="draw-button" disabled={!game.last_discarded_tile}><ArrowLeft size={15} /> Atılanı al</button></div></div></div></section></div></main>;
}

function PlayerBadge({ player, active, vertical = false }: { player: Player; active: boolean; vertical?: boolean }) { return <div className={`player-badge ${active ? 'active' : ''} ${vertical ? 'vertical' : ''}`}><Avatar name={player.avatar} size="md" active={active} /><div><strong>{player.nickname}</strong><span>{active ? 'Sırası' : `${player.score} puan`}</span></div>{active && <div className="active-wave"><Radio size={13} /></div>}</div>; }

export default App;
