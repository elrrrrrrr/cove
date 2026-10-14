#!/usr/bin/env node
// Deterministic poster layout using the existing icon and actual application captures.
import { createRequire } from 'node:module';
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const require = createRequire(import.meta.url);
const sharp = require(process.env.COVE_BRAND_SHARP || 'sharp');
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const picture = async relative => 'data:image/png;base64,' + (await readFile(path.join(root, relative))).toString('base64');
const [icon, news, book, music] = await Promise.all([
  picture('docs/brand/icon.png'), picture('docs/assets/hacker-news.png'),
  picture('docs/assets/txt-chapters.png'), picture('docs/assets/zhaolei-player.png')
]);
const font = 'PingFang SC,Heiti SC,Noto Sans CJK SC,Helvetica Neue,sans-serif';
function phone(image, x, y, width, id, angle = 0) {
  const height = width * 2622 / 1206;
  return `<g transform="rotate(${angle} ${x+width/2} ${y+height/2})"><rect x="${x-7}" y="${y-7}" width="${width+14}" height="${height+14}" rx="${width*.14}" fill="#03070c" filter="url(#shadow)"/><defs><clipPath id="${id}"><rect x="${x}" y="${y}" width="${width}" height="${height}" rx="${width*.12}"/></clipPath></defs><image href="${image}" x="${x}" y="${y}" width="${width}" height="${height}" clip-path="url(#${id})"/><rect x="${x+width*.34}" y="${y+width*.055}" width="${width*.32}" height="${width*.04}" rx="6" fill="#03070c"/></g>`;
}
const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1800" height="1020" viewBox="0 0 1800 1020">
<defs><filter id="shadow" x="-30%" y="-20%" width="160%" height="150%"><feDropShadow dx="0" dy="16" stdDeviation="14" flood-color="#000" flood-opacity=".35"/></filter></defs>
<rect width="1800" height="1020" rx="32" fill="#101923"/>
<image href="${icon}" x="100" y="92" width="100" height="100"/>
<text x="225" y="160" font-family="${font}" font-size="76" font-weight="600" fill="#f7f6f1">Cove</text>
<text x="102" y="277" font-family="${font}" font-size="22" letter-spacing="4" fill="#cbbcf1">YOUR READING SPACE</text>
<text x="98" y="402" font-family="${font}" font-size="71" font-weight="600" fill="#f7f6f1">网页、NAS、</text>
<text x="98" y="497" font-family="${font}" font-size="71" font-weight="600" fill="#f7f6f1">本地文件。</text>
<text x="98" y="602" font-family="${font}" font-size="71" font-weight="600" fill="#cbbcf1">都能好好读。</text>
<text x="103" y="717" font-family="${font}" font-size="26" fill="#b7c4c8">读 Hacker News，TXT 自动生成目录，听一首赵雷。</text>
<path d="M103 777H600" stroke="#3c4a55" stroke-width="1"/>
<text x="103" y="825" font-family="${font}" font-size="23" fill="#edf0ed">原生阅读</text><text x="273" y="825" font-family="${font}" font-size="23" fill="#edf0ed">可配置站点</text><text x="475" y="825" font-family="${font}" font-size="23" fill="#edf0ed">本地优先</text>
${phone(news, 791, 214, 270, 'news', -4)}
${phone(book, 1109, 146, 270, 'book')}
${phone(music, 1427, 214, 270, 'music', 4)}
<text x="850" y="906" font-family="${font}" font-size="24" fill="#b7c4c8">Hacker News</text><text x="1162" y="843" font-family="${font}" font-size="24" fill="#b7c4c8">TXT 自动章节</text><text x="1482" y="906" font-family="${font}" font-size="24" fill="#b7c4c8">赵雷 · 成都</text>
</svg>`;
if (process.argv.includes('--svg')) await writeFile(path.join(root, 'docs/brand/hero.svg'), svg);
await sharp(Buffer.from(svg)).png().toFile(path.join(root, 'docs/brand/hero.png'));
const source = `<html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Cove 品牌展示</title><style>body{margin:0;background:#e9e8e4;font:16px/1.6 system-ui;color:#17232a}main{max-width:1100px;margin:48px auto;padding:0 24px}img{width:100%;display:block;border-radius:20px}h1{font-size:26px}a{color:#574698}.note{color:#5c6970}nav{display:flex;gap:24px;margin:24px 0}</style><main><h1>Cove · 品牌展示</h1><p class="note">沿用 App 图标与真实生产视图，Hacker News、Rust 阅读与赵雷试听。</p><img src="hero.png" alt="Cove：网页、NAS、本地文件，都能好好读"><nav><a href="hero.png" download>下载 PNG</a><a href="../../README.md">查看 README</a></nav><p class="note">屏幕内容来自 ExampleShowcaseTests：Hacker News 使用公开首页快照，TXT 经 TextPaginator 自动分章，目录与正文由生产组件渲染，音乐使用公开试听流与真实封面。版式源代码在 scripts/render-brand.mjs。</p></main></html>`;
await writeFile(path.join(root,'docs/brand/preview.html'),source);
console.log('Rendered brand poster from icon and actual captures');
