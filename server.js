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
let roomWaiting = {}; // ルームマッチ待機用（選手）
let rooms = {};       // 稼働中の全ゲームルームの状態管理用

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

// Socket.ioのメイン処理
io.on('connection', (socket) => {
  console.log('接続されました:', socket.id);

  // 1. 通常のマッチング（ランダムマッチ）
  socket.on('join_matchmaking', (data) => {
    // 修正: data.userName -> data.name に変更
    socket.userName = data?.name || "一般ナギソ";

    if (waitingPlayer && waitingPlayer.id !== socket.id) {
      const roomName = `room_${socket.id}_${waitingPlayer.id}`;
      
      socket.join(roomName);
      waitingPlayer.join(roomName);

      const isFirst = Math.random() > 0.5;

      // ルーム管理に登録
      rooms[roomName] = {
        player1: isFirst ? socket : waitingPlayer,
        player2: isFirst ? waitingPlayer : socket,
        spectators: []
      };

      // 役割のフラグ付け
      rooms[roomName].player1.isPlayer1 = true;
      rooms[roomName].player2.isPlayer1 = false;

      socket.gameRoom = roomName;
      waitingPlayer.gameRoom = roomName;

      // それぞれにゲーム開始を通知
      socket.emit('game_start', { isFirst: isFirst, enemyName: waitingPlayer.userName });
      waitingPlayer.emit('game_start', { isFirst: !isFirst, enemyName: socket.userName });

      waitingPlayer = null;
      notifyDiscord(`\nランダムマッチが成立したぞ！👀 (${socket.userName} vs 相手)`);
    } else {
      waitingPlayer = socket;
      notifyDiscord(`\nランダムマッチ待機中の人が現れたぞ！ (${socket.userName})`);
    }
  });

  // 2. ルームマッチ（合言葉 - 選手として参加）
  socket.on('join_room_match', (data) => {
    const roomName = data.roomName;
    // 修正: data.userName -> data.name に変更
    socket.userName = data.name || "部屋ナギソ";
    const roomId = `room_${roomName}`;

    if (roomWaiting[roomName] && roomWaiting[roomName].id !== socket.id) {
      const opponent = roomWaiting[roomName];
      delete roomWaiting[roomName]; 

      opponent.join(roomId);
      socket.join(roomId);
      
      const isFirst = Math.random() > 0.5;
      
      // ルーム管理の初期化
      rooms[roomId] = {
        player1: isFirst ? socket : opponent,
        player2: isFirst ? opponent : socket,
        spectators: rooms[roomId]?.spectators || [] // 先に観戦者が待機していた場合は引き継ぐ
      };

      rooms[roomId].player1.isPlayer1 = true;
      rooms[roomId].player2.isPlayer1 = false;

      socket.gameRoom = roomId;
      opponent.gameRoom = roomId;

      // 選手へ通知
      socket.emit('game_start', { isFirst: isFirst, enemyName: opponent.userName });
      opponent.emit('game_start', { isFirst: !isFirst, enemyName: socket.userName });
      
      // 既に待機していた観戦者がいれば試合開始を通知
      rooms[roomId].spectators.forEach(specSocket => {
        specSocket.emit('spectator_game_start', { 
          player1: rooms[roomId].player1.userName, 
          player2: rooms[roomId].player2.userName 
        });
      });

      console.log(`ルームマッチ成立: ${roomName} (${rooms[roomId].player1.userName} vs ${rooms[roomId].player2.userName})`);
    } else {
      roomWaiting[roomName] = socket;
      socket.myWaitingRoomName = roomName; 
      console.log(`ルームマッチ選手待機中: ${roomName} (${socket.userName})`);
    }
  });

  // 3. ルームマッチ（合言葉 - 観戦者として参加）
  // 修正: 'join_room_spectator' -> 'join_spectate' に変更
  socket.on('join_spectate', (data) => {
    const roomName = data.roomName;
    socket.userName = data.userName || "観戦ナギソ";
    const roomId = `room_${roomName}`;
    
    socket.join(roomId);
    socket.gameRoom = roomId;
    socket.isSpectator = true;

    if (!rooms[roomId]) {
      rooms[roomId] = { player1: null, player2: null, spectators: [] };
    }
    rooms[roomId].spectators.push(socket);
    console.log(`👁️ 観戦者が入室しました: ルーム【${roomName}】(${socket.userName})`);

    // すでに両選手が揃って対戦中であれば、その場でプレイヤー名を同期して観戦画面へ移行させる
    const currentRoom = rooms[roomId];
    if (currentRoom.player1 && currentRoom.player2) {
      socket.emit('spectator_game_start', { 
        player1: currentRoom.player1.userName, 
        player2: currentRoom.player2.userName 
      });
    }
  });

  // 追加: マッチングキャンセル処理
  socket.on('cancel_matchmaking', () => {
    // ランダムマッチの待機キャンセル
    if (waitingPlayer && waitingPlayer.id === socket.id) {
      waitingPlayer = null;
      console.log(`ランダムマッチ待機キャンセル: ${socket.id}`);
    }
    // ルームマッチの待機キャンセル
    if (socket.myWaitingRoomName && roomWaiting[socket.myWaitingRoomName] === socket) {
      delete roomWaiting[socket.myWaitingRoomName];
      console.log(`ルームマッチ待機キャンセル: ${socket.myWaitingRoomName}`);
    }
  });

  // 追加: 観戦者への状態の同期・中継
  socket.on('update_room_state', (data) => {
    if (socket.gameRoom && rooms[socket.gameRoom]) {
      const currentRoom = rooms[socket.gameRoom];
      
      // 送信元の最新状態をソケットに保持しておく（途中から入ってきた観戦者などのため）
      socket.playerState = data;

      // プレイヤー1とプレイヤー2の現在の状態を取得（まだない場合はダミー値）
      const p1State = currentRoom.player1?.playerState || { 
        hp: 30, currentMana: 1, maxMana: 1, handLength: 0, deckLength: 30, name: currentRoom.player1?.userName || "プレイヤー1" 
      };
      const p2State = currentRoom.player2?.playerState || { 
        hp: 30, currentMana: 1, maxMana: 1, handLength: 0, deckLength: 30, name: currentRoom.player2?.userName || "プレイヤー2" 
      };

      // 観戦者全員に最新ステータスを配信する
      currentRoom.spectators.forEach(spec => {
        spec.emit('spectator_update', {
          p1: p1State,
          p2: p2State,
          isP1Turn: data.isP1Turn,
          latestLog: data.latestLog
        });
      });
    }
  });

  // 4. ゲームプレイ中のリアルタイム通信（対戦相手 ＆ 観戦者全員に転送）
  socket.on('play_card', (data) => {
    if (socket.gameRoom) {
      // 送信者がPlayer1かどうかをデータに付与（観戦者がどちらの行動か見分けるため）
      data.isPlayer1 = socket.isPlayer1;
      // 自分以外の、ルーム内の全員（対戦相手＋観戦者）に送信
      socket.to(socket.gameRoom).emit('opponent_play_card', data);
    }
  });

  socket.on('end_turn', (data) => {
    if (socket.gameRoom) {
      const currentRoom = rooms[socket.gameRoom];
      if (currentRoom) {
        // 次のターンがどっちになるかを観戦者用に付与
        data.player1TurnNow = !socket.isPlayer1;
      }
      socket.to(socket.gameRoom).emit('opponent_end_turn', data);
    }
  });

  // 5. 切断時のクリーンアップ処理
  socket.on('disconnect', () => {
    console.log('切断されました:', socket.id);
    
    // 通常マッチの待機中に切断された場合
    if (waitingPlayer && waitingPlayer.id === socket.id) {
      waitingPlayer = null;
    }
    
    // ルームマッチの選手待機中に切断された場合
    if (socket.myWaitingRoomName && roomWaiting[socket.myWaitingRoomName] === socket) {
      delete roomWaiting[socket.myWaitingRoomName];
      console.log(`ルームマッチ待機キャンセル: ${socket.myWaitingRoomName}`);
    }
    
    // 対戦中、または観戦中に切断された場合
    if (socket.gameRoom && rooms[socket.gameRoom]) {
      const currentRoom = rooms[socket.gameRoom];

      if (socket.isSpectator) {
        // 抜けたのが観戦者の場合、リストから除外
        currentRoom.spectators = currentRoom.spectators.filter(spec => spec.id !== socket.id);
        console.log(`👁️ 観戦者が退出しました: ${socket.id}`);
      } else {
        // 抜けたのが選手の場合、ルーム全員に切断を通知してルームを解体
        socket.to(socket.gameRoom).emit('opponent_disconnected');
        
        // ルームにいる全員を退室させる
        if (currentRoom.player1) currentRoom.player1.gameRoom = null;
        if (currentRoom.player2) currentRoom.player2.gameRoom = null;
        currentRoom.spectators.forEach(spec => spec.gameRoom = null);
        
        delete rooms[socket.gameRoom];
        console.log(`⚔️ 選手切断によりルームを解体しました: ${socket.gameRoom}`);
      }
    }
  });
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  console.log(`サーバーがポート ${PORT} で起動しました`);
});
