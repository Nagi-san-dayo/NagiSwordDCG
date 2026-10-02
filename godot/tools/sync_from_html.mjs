// index.html（HTML 版）からカード・能力・デッキのデータを取り出して Godot 版に反映する。
//
//   node godot/tools/sync_from_html.mjs
//
// 生成するもの（どれも git には入れない。index.html が唯一の正）:
//   godot/data/cards.json      ← const cardPool = [...]
//   godot/data/abilities.json  ← abilityDictionary: [...]
//   godot/data/decks.json      ← プリセットデッキ（agro / ramp / combo）と CPU のカードプール
//   godot/images/*             ← images/ の画像をコピー
//
// 取り出せないときはエラーで止まる。Godot 版がまだ対応していない能力などは警告だけ出す
// （GitHub Actions 上では ::warning:: / ::error:: の注釈として表示される）。

import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const GODOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const REPO_DIR = path.resolve(GODOT_DIR, "..");
const HTML_PATH = path.join(REPO_DIR, "index.html");
const IMAGE_EXTS = new Set([".png", ".jpg", ".jpeg", ".webp", ".svg"]);
const IN_CI = !!process.env.GITHUB_ACTIONS;

let errorCount = 0;
let warningCount = 0;

function warn(msg) {
    warningCount++;
    console.log(IN_CI ? `::warning file=index.html::${msg}` : `警告: ${msg}`);
}

function fail(msg) {
    errorCount++;
    console.log(IN_CI ? `::error file=index.html::${msg}` : `エラー: ${msg}`);
}

// `marker` の直後にある [ ... ] を、文字列やコメントを考慮して括弧の対応で切り出す
function extractArray(src, marker) {
    const at = src.indexOf(marker);
    if (at < 0) return null;
    const start = src.indexOf("[", at + marker.length - 1);
    let depth = 0;
    for (let i = start; i < src.length; i++) {
        const ch = src[i];
        if (ch === '"' || ch === "'" || ch === "`") {
            for (i++; i < src.length && src[i] !== ch; i++) {
                if (src[i] === "\\") i++;
            }
        } else if (ch === "/" && src[i + 1] === "/") {
            i = src.indexOf("\n", i);
        } else if (ch === "/" && src[i + 1] === "*") {
            i = src.indexOf("*/", i) + 1;
        } else if (ch === "[") {
            depth++;
        } else if (ch === "]" && --depth === 0) {
            return src.slice(start, i + 1);
        }
    }
    return null;
}

function evalArray(literal, label) {
    try {
        // 中身は JS のオブジェクトリテラル（末尾カンマや ' 文字列もある）なので JSON ではなく JS として評価する
        return vm.runInNewContext(`(${literal})`, {}, { timeout: 1000 });
    } catch (e) {
        fail(`${label} を読み取れませんでした: ${e.message}`);
        return null;
    }
}

function readArray(src, marker, label) {
    const literal = extractArray(src, marker);
    if (literal == null) {
        fail(`index.html に「${marker}」が見つかりません（${label}）`);
        return null;
    }
    return evalArray(literal, label);
}

// Godot 版（game.gd）が知っている能力の種類。文字列リテラルを拾うだけの簡易判定
function knownAbilityTypes() {
    const gd = fs.readFileSync(path.join(GODOT_DIR, "scripts", "game.gd"), "utf8");
    return new Set([...gd.matchAll(/"([a-z_]+)"/g)].map((m) => m[1]));
}

function writeJson(rel, value) {
    const file = path.join(GODOT_DIR, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(value, null, 1) + "\n");
}

const html = fs.readFileSync(HTML_PATH, "utf8");

// ---- カード ----
const cardPool = readArray(html, "const cardPool = [", "cardPool") ?? [];
const knownTypes = knownAbilityTypes();
const unknownTypes = new Map();
cardPool.forEach((card, i) => {
    const where = `cardPool[${i}]「${card?.name ?? "?"}」`;
    if (typeof card?.name !== "string" || !card.name) fail(`${where}: name がありません`);
    for (const key of ["cost", "power"]) {
        if (!Number.isFinite(card?.[key])) fail(`${where}: ${key} が数値ではありません`);
    }
    card.abilities ??= [];
    card.abilityText ??= "";
    card.image ??= "images/mate.png";
    if (!Array.isArray(card.abilities)) {
        fail(`${where}: abilities が配列ではありません`);
        return;
    }
    // 「パン屋さん」の grants（付与する能力）も確認する
    for (const ab of [card.abilities, ...card.abilities.map((a) => a?.grants ?? [])].flat()) {
        if (!ab?.type) fail(`${where}: type の無い能力があります`);
        else if (!knownTypes.has(ab.type)) {
            if (!unknownTypes.has(ab.type)) unknownTypes.set(ab.type, []);
            unknownTypes.get(ab.type).push(card.name);
        }
    }
    if (!fs.existsSync(path.join(REPO_DIR, card.image))) {
        warn(`${where}: 画像 ${card.image} がありません（mate.png で表示されます）`);
    }
});
for (const [type, names] of unknownTypes) {
    warn(`能力 "${type}" は Godot 版の game.gd に未実装です（${names.join("、")}）。カードは追加されますが能力は発動しません`);
}

// ---- 能力一覧 ----
const abilities = readArray(html, "abilityDictionary: [", "abilityDictionary") ?? [];

// ---- プリセットデッキと CPU のカードプール ----
const decks = {};
for (const type of ["agro", "ramp", "combo"]) {
    decks[type] = readArray(html, `type === '${type}') pPool = [`, `${type} デッキ`);
}
decks.cpu = readArray(html, "let cPool = [", "CPU のカードプール");
for (const [type, list] of Object.entries(decks)) {
    for (const idx of list ?? []) {
        if (!Number.isInteger(idx) || idx < 0 || idx >= cardPool.length) {
            fail(`${type} デッキのカード番号 ${idx} が cardPool の範囲外です`);
        }
    }
}

if (errorCount > 0) {
    console.log(`\n${errorCount} 件のエラーがあったので書き出しを中止しました。`);
    process.exit(1);
}

writeJson("data/cards.json", cardPool);
writeJson("data/abilities.json", abilities);
writeJson("data/decks.json", decks);

// ---- 画像 ----
const srcImages = path.join(REPO_DIR, "images");
const dstImages = path.join(GODOT_DIR, "images");
fs.mkdirSync(dstImages, { recursive: true });
let copied = 0;
for (const name of fs.readdirSync(srcImages)) {
    if (!IMAGE_EXTS.has(path.extname(name).toLowerCase())) continue;
    fs.copyFileSync(path.join(srcImages, name), path.join(dstImages, name));
    copied++;
}

console.log(`カード ${cardPool.length} 枚 / 能力 ${abilities.length} 個 / 画像 ${copied} 枚を Godot 版に反映しました（警告 ${warningCount} 件）。`);
