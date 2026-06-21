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
    } else {
      waitingPlayer = socket;
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