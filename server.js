const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const path = require('path');

const app = express();
app.use(cors());

// 静的ファイルの配信設定
app.use(express.static(__dirname));

// ルートURLにアクセスがあったら index.html を返す
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});

const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*", 
    methods: ["GET", "POST"]
  }
});

// マッチング用の管理変数
let waitingPlayer = null; 
// ルームマッチ用の管理 (P1, P2, 観戦者を管理)
let roomGames = {}; 

// Discord Webhookの設定
const DISCORD_WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL || 'https://discord.com/api/webhooks/1518233626033127584/afbC-V7S9t7GkEvhMV8ZADhHVWxCVFlCghw7cP6QOZTjSpD7-YUgNpkJFBfjRTyXqQQD';

async function notifyDiscord(message) {
  if (!DISCORD_WEBHOOK_URL) return;

  const now = new Date();
  const timeString = now.toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });
  const finalMessage = `[${timeString}]\n${message}`;

  try {
    await fetch(DISCORD_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ content: finalMessage })
    });
  } catch (error) {
    console.error('Discord通知に失敗しました:', error);
  }
}

io.on('connection', (socket) => {
  console.log('接続されました:', socket.id);

  // 1. 通常のマッチング（ランダムマッチ）
  socket.on('join_matchmaking', () => {
    if (waitingPlayer && waitingPlayer.id !== socket.id) {
      const roomName = `room_${socket.id}_${waitingPlayer.id}`;
      socket.join(roomName);
      waitingPlayer.join(roomName);

      const isFirst = Math.random() > 0.5;

      // roleを付与してゲーム開始
      socket.emit('game_start', { isFirst: isFirst, role: 'p2' });
      waitingPlayer.emit('game_start', { isFirst: !isFirst, role: 'p1' });

      socket.opponent = waitingPlayer;
      waitingPlayer.opponent = socket;
      
      socket.gameRoom = roomName;
      waitingPlayer.gameRoom = roomName;
      socket.playerRole = 'p2';
      waitingPlayer.playerRole = 'p1';

      waitingPlayer = null;
      notifyDiscord('\nマッチングが成立したぞ！👀');
    } else {
      waitingPlayer = socket;
      notifyDiscord('\nマッチ待機中の人が現れたぞ！');
    }
  });

  // 2. ルームマッチ（合言葉）と観戦機能
  socket.on('join_room_match', (data) => {
    const roomName = data.roomName;
    const roomId = `room_${roomName}`;

    // ルームが存在しない、または誰もいない場合
    if (!roomGames[roomId] || (!roomGames[roomId].p1 && !roomGames[roomId].p2)) {
      roomGames[roomId] = { p1: socket, p2: null, spectators: [], name: roomName };
      socket.join(roomId);
      socket.gameRoom = roomId;
      socket.playerRole = 'p1';
      console.log(`ルーム作成: ${roomName} (P1)`);
    } 
    // P2として参加
    else if (!roomGames[roomId].p2) {
      roomGames[roomId].p2 = socket;
      socket.join(roomId);
      socket.gameRoom = roomId;
      socket.playerRole = 'p2';

      // 互いを相手として紐付け
      const p1 = roomGames[roomId].p1;
      socket.opponent = p1;
      p1.opponent = socket;

      const isFirst = Math.random() > 0.5;
      p1.emit('game_start', { isFirst: isFirst, role: 'p1' });
      socket.emit('game_start', { isFirst: !isFirst, role: 'p2' });
      
      console.log(`ルームマッチ成立: ${roomName} (P2参加)`);
    } 
    // 3人目以降は観戦者として参加
    else {
      roomGames[roomId].spectators.push(socket);
      socket.join(roomId);
      socket.gameRoom = roomId;
      socket.playerRole = 'spectator';

      socket.emit('spectator_start', { roomName: roomName });
      
      // P1とP2に観戦者へ最新状態を送るよう要求
      if (roomGames[roomId].p1) roomGames[roomId].p1.emit('request_full_state');
      if (roomGames[roomId].p2) roomGames[roomId].p2.emit('request_full_state');
      console.log(`観戦者が参加: ${roomName}`);
    }
  });

  // 3. 観戦者への状態ブロードキャスト
  socket.on('update_spectator_state', (state) => {
    // 部屋全体（観戦者含む）に状態を通知（送信元以外）
    socket.to(socket.gameRoom).emit('spectator_state_updated', {
      role: socket.playerRole,
      state: state
    });
  });

  socket.on('send_spectator_log', (msg) => {
    socket.to(socket.gameRoom).emit('spectator_log_added', msg);
  });

  // 4. ゲームプレイ中の通信（プレイヤー同士）
  socket.on('play_card', (data) => {
    if (socket.opponent) {
      socket.opponent.emit('opponent_play_card', data);
    }
  });

  socket.on('end_turn', (data) => {
    if (socket.opponent) {
      socket.opponent.emit('opponent_end_turn', data);
    }
  });

  // 5. 切断時の処理
  socket.on('disconnect', () => {
    console.log('切断されました:', socket.id);
    
    if (waitingPlayer && waitingPlayer.id === socket.id) {
      waitingPlayer = null;
    }
    
    // ルームマッチ・観戦時の切断処理
    if (socket.gameRoom && roomGames[socket.gameRoom]) {
      const room = roomGames[socket.gameRoom];
      
      if (socket.playerRole === 'spectator') {
        // 観戦者の離脱
        room.spectators = room.spectators.filter(s => s.id !== socket.id);
        console.log(`観戦者が離脱: ${socket.gameRoom}`);
      } else {
        // プレイヤーの離脱：相手に通知してルームを解散
        if (socket.opponent) {
          socket.opponent.emit('opponent_disconnected');
          socket.opponent.opponent = null; 
        }
        delete roomGames[socket.gameRoom];
      }
    } 
    // ランダムマッチ時の切断処理
    else if (socket.opponent) {
      socket.opponent.emit('opponent_disconnected');
      socket.opponent.opponent = null; 
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`サーバーがポート ${PORT} で起動しました`);
});
