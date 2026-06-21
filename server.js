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

// 【修正2】変数の宣言は1回にまとめる
let waitingPlayer = null; 

// Discord通知の追加の案
const DISCORD_WEBHOOK_URL = process.env.DISCORD_WEBHOOK_URL || 'ここにコピーしたWebhookURLを貼り付ける';

// 【修正1】引数に message を追加
async function notifyDiscord(message) {
  // URLが設定されていない場合は何もしない
  if (!DISCORD_WEBHOOK_URL || DISCORD_WEBHOOK_URL === 'ここにコピーしたWebhookURLを貼り付ける') return;

  const now = new Date();
  // 現在時刻も表示
  const timeString = now.toLocaleString('ja-JP', { timeZone: 'Asia/Tokyo' });

  // 受け取った message を組み込む
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
      notifyDiscord('⚔️ **ナギソDCG** ⚔️\nマッチングが成立し、新しい対戦が始まりました！👀');
    } else {
      waitingPlayer = socket;
      // マッチング待機時のDiscord通知メッセージ
      notifyDiscord('⚔️ **ナギソDCG** ⚔️\nオンライン対戦の待機列にプレイヤーが入りました！誰か対戦しませんか？🙋');
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