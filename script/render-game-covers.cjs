// Renders the lobby covers from the real 3D scenes into public/images/games/.
// Usage: RSC_PLAYWRIGHT=/abs/node_modules/playwright node script/render-game-covers.cjs coin=v2 dice=v2 ...
// Use a new version for each re-rendered game and set it in COVER_VERSIONS (lib/game-covers.js):
// production caches /plugins for a year. Existing files are never overwritten.
const fs = require("node:fs"), path = require("node:path");
const { chromium } = require(process.env.RSC_PLAYWRIGHT || "playwright");
const repo = path.resolve(__dirname, "..");
const jobs = process.argv.slice(2).map((arg) => arg.split("="));
if (!jobs.length || jobs.some(([g, v]) => !g || !/^v\d+$/.test(v || ""))) throw new Error("usage: render-game-covers.cjs game=vN ...");
const lib = path.join(repo, "assets/javascripts/discourse/lib");
// Same bundle the forum loads (older builds stay in public/ for pages already open).
const three = path.basename(fs.readFileSync(path.join(lib, "game-3d.js"), "utf8").match(/THREE_PATH = "([^"]+)"/)[1]);
const files = {
  "/three.js": path.join(repo, "public/javascripts", three),
  "/scenes.js": path.join(lib, "game-3d-scenes.js"),
  "/covers.js": path.join(lib, "game-covers.js"),
};
const shim = `import * as T from "/three.js"; import { buildScene } from "/scenes.js";
export const supports3d = () => true;
export async function createGameScene(game, host, options) { const ctl = buildScene(T, game, host, options); await ctl.ready; return ctl; }`;
const page = `<!doctype html><meta charset=utf-8><body style="margin:0"><script type=module>
import { createGameScene } from "/game-3d.js"; import { applyCover } from "/covers.js";
window.render = async (game, w, h) => {
  const host = document.createElement("div"); host.style.cssText = "width:" + w + "px;height:" + h + "px"; document.body.appendChild(host);
  const ctl = await createGameScene(game, host, { cover: true }); applyCover(ctl, game);
  ctl.snapshot(); const url = host.querySelector("canvas").toDataURL("image/webp", 0.9); ctl.dispose(); host.remove(); return url;
};
window.ready = true;
</script>`;
(async () => {
  const browser = await chromium.launch({ args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
  const tab = await browser.newPage({ deviceScaleFactor: 2 });
  await tab.route("http://covers.local/**", (route) => {
    const p = new URL(route.request().url()).pathname;
    if (p === "/") return route.fulfill({ contentType: "text/html", body: page });
    if (p === "/game-3d.js") return route.fulfill({ contentType: "text/javascript", body: shim });
    const body = fs.readFileSync(files[p], "utf8").replace('from "./game-3d";', 'from "/game-3d.js";');
    return route.fulfill({ contentType: "text/javascript", body });
  });
  tab.on("pageerror", (e) => console.error(e.message));
  await tab.goto("http://covers.local/");
  await tab.waitForFunction(() => window.ready);
  const out = path.join(repo, "public/images/games");
  fs.mkdirSync(out, { recursive: true });
  for (const [game, version] of jobs) {
    // 534x267 CSS px at the scene's 1.5x pixel-ratio cap = 801x400 image (2x of 400x200 card art).
    const url = await tab.evaluate(([g]) => window.render(g, 534, 267), [game]);
    const file = path.join(out, `cover-${game}-${version}.webp`);
    if (fs.existsSync(file)) throw new Error(`${file} exists; choose a new version`);
    fs.writeFileSync(file, Buffer.from(url.split(",")[1], "base64"));
    console.log(path.relative(repo, file), fs.statSync(file).size, "bytes");
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
