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
let roomWaiting = {}; // ルームマッチ用

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

// Socket.ioのメイン処理（1つに統合）
io.on('connection', (socket) => {
  console.log('接続されました:', socket.id);

  // 1. 通常のマッチング（ランダムマッチ）
  socket.on('join_matchmaking', () => {
    if (waitingPlayer && waitingPlayer.id !== socket.id) {
      const roomName = `room_${socket.id}_${waitingPlayer.id}`;
      socket.join(roomName);
      waitingPlayer.join(roomName);

      const isFirst = Math.random() > 0.5;

      socket.emit('game_start', { isFirst: isFirst });
      waitingPlayer.emit('game_start', { isFirst: !isFirst });

      // お互いを相手として紐付け
      socket.opponent = waitingPlayer;
      waitingPlayer.opponent = socket;
      
      // ルーム名も保持しておく
      socket.gameRoom = roomName;
      waitingPlayer.gameRoom = roomName;

      waitingPlayer = null;
      notifyDiscord('\nマッチングが成立したぞ！👀');
    } else {
      waitingPlayer = socket;
      notifyDiscord('\nマッチ待機中の人が現れたぞ！');
    }
  });

  // 2. ルームマッチ（合言葉）
  socket.on('join_room_match', (data) => {
    const roomName = data.roomName;

    if (roomWaiting[roomName] && roomWaiting[roomName].id !== socket.id) {
      const opponent = roomWaiting[roomName];
      delete roomWaiting[roomName]; 

      const isFirst = Math.random() > 0.5;
      const roomId = `room_${roomName}`;
      
      opponent.join(roomId);
      socket.join(roomId);
      
      // 通常マッチと同様に相手とルームを紐付け
      socket.opponent = opponent;
      opponent.opponent = socket;
      socket.gameRoom = roomId;
      opponent.gameRoom = roomId;

      opponent.emit('game_start', { isFirst: isFirst });
      socket.emit('game_start', { isFirst: !isFirst });
      
      console.log(`ルームマッチ成立: ${roomName}`);
    } else {
      roomWaiting[roomName] = socket;
      socket.myWaitingRoomName = roomName; 
      console.log(`ルームマッチ待機中: ${roomName}`);
    }
  });

  // 3. ゲームプレイ中の通信（通常・ルーム共通）
  socket.on('play_card', (data) => {
    if (socket.opponent) {
      socket.opponent.emit('opponent_play_card', data);
    }
  });

  socket.on('end_turn', () => {
    if (socket.opponent) {
      socket.opponent.emit('opponent_end_turn');
    }
  });

  // 4. 切断時の処理（通常・ルーム共通＆待機キャンセル対応）
  socket.on('disconnect', () => {
    console.log('切断されました:', socket.id);
    
    // 通常マッチの待機中に切断された場合
    if (waitingPlayer && waitingPlayer.id === socket.id) {
      waitingPlayer = null;
    }
    
    // ルームマッチの待機中に切断された場合
    if (socket.myWaitingRoomName && roomWaiting[socket.myWaitingRoomName] === socket) {
      delete roomWaiting[socket.myWaitingRoomName];
      console.log(`ルームマッチ待機キャンセル: ${socket.myWaitingRoomName}`);
    }
    
    // 対戦中に切断された場合
    if (socket.opponent) {
      socket.opponent.emit('opponent_disconnected');
      socket.opponent.opponent = null; 
      socket.opponent.gameRoom = null;
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`サーバーがポート ${PORT} で起動しました`);
});
