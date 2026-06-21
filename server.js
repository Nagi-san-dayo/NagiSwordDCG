const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');
const path = require('path'); // ファイルのパスを扱うための標準モジュール

const app = express();
app.use(cors());

// ーーー 追加部分：index.html を配信する設定 ーーー
// publicフォルダ内（今回は同じ階層を想定）の静的ファイルを配信
app.use(express.static(__dirname));

// ルートURLにアクセスがあったら index.html を返す
app.get('/', (req, res) => {
  res.sendFile(path.join(__dirname, 'index.html'));
});
// ーーーーーーーーーーーーーーーーーーーーーーーーー

const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: "*", 
    methods: ["GET", "POST"]
  }
});

let waitingPlayer = null; 


// Discord通知の追加の案
// Discordでプレイヤーがオンラインキューを入れたときに通知が出るような仕組みの追加です。
// 通知を送るDiscordのチャンネルでwebhookのURLを発行する必要があります。
// 1. 通知を送りたいDiscordのテキストチャンネルの歯車マークを開く。
// 2. 連携サービス→ウェブフック→新しいウェブフックから作成。
// 3. アイコンや名前を設定したらウェブフックURLをコピー。
const DISCORD_WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL || 'https://discord.com/api/webhooks/1518233626033127584/afbC-V7S9t7GkEvhMV8ZADhHVWxCVFlCghw7cP6QOZTjSpD7-YUgNpkJFBfjRTyXqQQD';

async function notifyDiscord() {
  // URLが設定されていない場合は何もしない
  if (!DISCORD_WEBHOOK_URL || DISCORD_WEBHOOK_URL === 'https://discord.com/api/webhooks/1518233626033127584/afbC-V7S9t7GkEvhMV8ZADhHVWxCVFlCghw7cP6QOZTjSpD7-YUgNpkJFBfjRTyXqQQD') return;

  const now = new Date();
  // 現在時刻も表示
  const timeString = now.toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });

  const finalMessage = `[${timeString}]\n${message}`;

  try {
    await fetch(DISCORD_WEBHOOK_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        content: finalMessage
      })
    });
  } catch (error) {
    console.error('Discord通知に失敗しました:', error);
  }
}

let waitingPlayer = null; 

io.on('connection', (socket) => {
  console.log('接続されました:', socket.id);

  socket.on('join_matchmaking', () => {
    if (waitingPlayer && waitingPlayer.id !== socket.id) {
      const roomName = `room_${socket.id}_${waitingPlayer.id}`;
      socket.join(roomName);
      waitingPlayer.join(roomName);

      const isFirst = Math.random() > 0.5;

      socket.emit('game_start', { isFirst: isFirst });
      waitingPlayer.emit('game_start', { isFirst: !isFirst });

      socket.opponent = waitingPlayer;
      waitingPlayer.opponent = socket;
      
      waitingPlayer = null;
      // マッチング成立時のDiscord通知メッセージ
      notifyDiscord('⚔️ **ナギソDCG** ⚔️\nマッチングが成立したぞ！👀');
    } else {
      waitingPlayer = socket;
      // マッチング待機時のDiscord通知メッセージ
      notifyDiscord('⚔️ **ナギソDCG** ⚔️\nマッチ待機中の人が現れたぞ！');
    }
  });

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

  socket.on('disconnect', () => {
    console.log('切断されました:', socket.id);
    
    if (waitingPlayer && waitingPlayer.id === socket.id) {
      waitingPlayer = null;
    }
    
    if (socket.opponent) {
      socket.opponent.emit('opponent_disconnected');
      socket.opponent.opponent = null; 
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`サーバーがポート ${PORT} で起動しました`);
});