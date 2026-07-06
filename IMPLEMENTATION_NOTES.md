# 千刃n & 逕侵穿突n 実装メモ

## 実装概要

### 1. 新能力の定義

#### 千刃n（せんじんn）
- **効果**: 自分の手札のカード全ての攻撃力をn上げる
- **タイプ**: sennjin
- **適用時**: カード使用時に即座に発動
- **スタック**: 複数枚使用時は効果が累積

#### 逕侵穿突n（けいしんせんとつn）
- **効果**: このカードの攻撃力がn以上なら、聖域を貫通して相手に直接ダメージを与える
- **タイプ**: keisin
- **適用時**: ダメージ計算時に貫通判定
- **特殊**: バリアを無視する

---

## オンライン対応の実装

### 問題点
オンライン対戦では、クライアント間でゲーム状態を同期する必要があります。
- バリア状態がサーバーを通じて正しく同期されない
- 相手プレイヤーの画面でバリアが無視されない

### 解決策

#### Step 1: playCardメソッド内での処理
```javascript
let localSyncData = syncData || { 
    chosenCardIndices: [], 
    chosenZenjiIndices: [], 
    discardIndex: -1,
    barrier_pierced: false  // ← 追加
};

// カードの能力をチェック
card.abilities.forEach(ab => {
    if (ab.type === "keisin" && card.power >= ab.value) {
        localSyncData.barrier_pierced = true;
    }
});
```

#### Step 2: ソケット通信時にsyncDataを送信
```javascript
if (isPlayer && !this.isCpuMode) {
    socket.emit('play_card', { 
        card: card, 
        currentMana: this.playerCurrentMana, 
        maxMana: this.playerMaxMana, 
        syncData: localSyncData  // barrier_pierceを含む
    });
}
```

#### Step 3: opponent_play_cardハンドラーで受信
```javascript
socket.on('opponent_play_card', (data) => {
    // syncDataにbarrier_pierceが含まれている
    if (data.syncData?.barrier_pierced) {
        this.cpuBarrier = 0;  // バリアを無視
    }
    this.playCard(data.card, false, data.syncData);
});
```

---

## cardPoolへの新カード追加

10枚の新カードを追加（両能力を組み合わせたバリエーション）:

1. **千刃1 逕侵穿突5** - コスト3
2. **千刃2 逕侵穿突8** - コスト5
3. **千刃1 逕侵穿突4** - コスト2 (速攻向け)
4. **千刃3 逕侵穿突10** - コスト7
5. **千刃2 逕侵穿突6** - コスト4
6. **千刃1 逕侵穿突3** - コスト1 (基本)
7. **千刃4 逕侵穿突12** - コスト9 (ハイパワー)
8. **千刃2 逕侵穿突7** - コスト6
9. **千刃1 逕侵穿突5** + 流水1 - コスト4
10. **千刃3 逕侵穿突9** - コスト8

---

## abilityDictionaryの更新

```javascript
{ name: "千刃X", desc: "自分の手札の全カードの攻撃力をX上げる。" },
{ name: "逕侵穿突X", desc: "このカードの攻撃力がX以上の場合、相手の聖域を貫通してダメージを与える。" }
```

---

## triggerAbilityメソッドへの追加実装

### 千刃の処理
```javascript
else if(type === "sennjin") {
    const hand = isPlayerTrigger ? this.playerHand : this.cpuHand;
    hand.forEach(c => {
        c.power += value;
    });
    if (isPlayerTrigger) {
        this.addLog(`  └【千刃${value}】手札のカード全ての攻撃力が ${value} 上がった！`);
    } else {
        this.addLog(`  └【千刃${value}】相手の手札のカード全ての攻撃力が ${value} 上がった！`);
    }
}
```

### 逕侵穿突の処理
```javascript
else if(type === "keisin") {
    // syncDataで貫通情報を受信している場合
    if (syncData?.barrier_pierced) {
        const targetBarrier = isPlayerTrigger ? 'cpuBarrier' : 'playerBarrier';
        this[targetBarrier] = 0;
    }
    // 攻撃力がn以上の場合のみダメージ計算
    if (card.power >= value) {
        this.applyDamage(!isPlayerTrigger, card.power);
        if (isPlayerTrigger) {
            this.addLog(`  └【逕侵穿突${value}】聖域を貫通して ${card.power} ダメージ！`);
        } else {
            this.addLog(`  └【逕侵穿突${value}】相手の聖域を貫通して ${card.power} ダメージ！`);
        }
    }
}
```

---

## CPU対戦での動作

CPU対戦では、localSyncDataにbarrier_pierceフラグが自動的に設定され、
triggerAbility呼び出し時に考慮されます。

---

## 次のステップ

1. index.htmlに上記の実装を統合
2. テスト（CPU対戦、オンライン対戦）
3. 必要に応じてバランス調整
