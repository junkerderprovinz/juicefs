/**
 * Standalone banner generator for the juicefs repo (not part of the shared
 * unraid-apps wrapper-banner generator, since this is its own repo).
 * Same technique as the house style: text rendered at local origin, then
 * positioned via <g transform> to avoid opentype.js NaN at large absolute X.
 * Run: node .github/assets/gen-banner.mjs
 */
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

const require = createRequire(import.meta.url);
const groot = execSync("npm root -g").toString().trim();
const opentype = require(`${groot}/opentype.js`);
const { Resvg } = require(`${groot}/@resvg/resvg-js`);
const HERE = dirname(fileURLToPath(import.meta.url));

async function font(file, url) {
  const p = join(tmpdir(), file);
  if (!existsSync(p)) { const r = await fetch(url); if (!r.ok) throw new Error(`${file} ${r.status}`); writeFileSync(p, Buffer.from(await r.arrayBuffer())); }
  const b = readFileSync(p);
  return opentype.parse(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
}
const bree = await font("jdp-BreeSerif-Regular.ttf", "https://github.com/google/fonts/raw/main/ofl/breeserif/BreeSerif-Regular.ttf");
const lato = await font("jdp-Lato-Regular.ttf", "https://github.com/google/fonts/raw/main/ofl/lato/Lato-Regular.ttf");
const bbox = (svg) => new Resvg(svg, { fitTo: { mode: "original" } }).getBBox();

// icon.svg is the JuiceFS mark ONLY, with the wordmark letters stripped from
// the upstream lockup -- the "JuiceFS" name is typeset here instead, same as
// every other repo's banner.
const W = 1600, H = 500, LOGO_INK = 400, LOGO_X = 165, GAP_LOGO_TEXT = 70, GAP_NAME_CLAIM = 16, CLAIM_CAP = 44, RIGHT_PAD = 120;
// Der Claim wird kleiner gesetzt, je breiter er ist (fitClaim gegen CLAIM_CAP).
// Ein langer, sachlicher Satz landet deshalb bei 29px statt der vollen 44px und
// wirkt neben dem Namen verloren. Kurz halten, so wie in den Schwester-Repos.
const NAME = "JuiceFS", CLAIM = "Squeezed into buckets, served as S3.";

const iconSrc = readFileSync(join(HERE, "icon.svg"), "utf8");
const iconInner = iconSrc.replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "");
const iconVb = { x: 0, y: 0, w: 512, h: 512 };

const mb = bbox(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="${iconVb.x} ${iconVb.y} ${iconVb.w} ${iconVb.h}">${iconInner}</svg>`);
const sM = LOGO_INK / Math.max(mb.width, mb.height);
const markW = mb.width * sM, markH = mb.height * sM;
const markTX = LOGO_X - mb.x * sM, markTY = H / 2 - markH / 2 - mb.y * sM;
const textX = LOGO_X + markW + GAP_LOGO_TEXT;
const maxNameW = W - textX - RIGHT_PAD;

// Versalhoehe an H gemessen, nicht an G: das G ueberschwingt oben und unten,
// wodurch der Name 3,6 Prozent kleiner gesetzt wuerde als in den Bannern, die
// der gemeinsame Wrapper-Generator baut. Beide messen jetzt dasselbe.
let ns = 110 / (bbox(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 400"><path d="${bree.getPath("H", 0, 300, 200).toPathData(2)}" fill="#000"/></svg>`).height / 200);
const adv = bree.getAdvanceWidth(NAME, ns);
if (adv > maxNameW) ns = ns * maxNameW / adv;
const nameD = bree.getPath(NAME, 0, 0, ns).toPathData(2);
const nb = bbox(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 5000 800"><path d="${bree.getPath(NAME, 0, 500, ns).toPathData(2)}" fill="#000"/></svg>`);
const nameH = nb.height, nameInkTop = nb.y - 500;

function fitClaim(text, maxW, cap) {
  let size = Math.min(cap, Math.floor((100 * maxW) / lato.getAdvanceWidth(text, 100)));
  for (; size > 10; size--) if (!lato.getPath(text, 0, 0, size).toPathData(2).includes("NaN")) return size;
  return 10;
}
const claimSize = fitClaim(CLAIM, maxNameW, CLAIM_CAP);
const claimAsc = lato.ascender * (claimSize / lato.unitsPerEm), claimDesc = -lato.descender * (claimSize / lato.unitsPerEm);
const groupH = nameH + GAP_NAME_CLAIM + claimAsc + claimDesc;
const top = H / 2 - groupH / 2;
const claimBaseline = Math.round(top + nameH + GAP_NAME_CLAIM + claimAsc);
const claimD = lato.getPath(CLAIM, 0, 0, claimSize).toPathData(2);

const THEMES = [
  { suf: "", bg: "#ffffff", name: "#1f2328", claim: "#5a5d5e" },
  { suf: "-dark", bg: "#0d1117", name: "#e6edf3", claim: "#9aa4ad" },
];
for (const t of THEMES) {
  const svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="juicefs">
  <rect width="${W}" height="${H}" fill="${t.bg}"/>
  <g transform="translate(${markTX.toFixed(2)},${markTY.toFixed(2)}) scale(${sM.toFixed(5)})">${iconInner}</g>
  <g transform="translate(${textX.toFixed(2)},${(top - nameInkTop).toFixed(2)})"><path d="${nameD}" fill="${t.name}"/></g>
  <g transform="translate(${textX.toFixed(2)},${claimBaseline})"><path d="${claimD}" fill="${t.claim}"/></g>
</svg>
`;
  writeFileSync(join(HERE, `banner${t.suf}.svg`), svg);
  writeFileSync(join(HERE, `banner${t.suf}.png`), new Resvg(svg, { background: t.bg, fitTo: { mode: "original" } }).render().asPng());
}
console.log("banner + banner-dark written");
