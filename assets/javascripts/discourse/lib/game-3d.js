import getURL from "discourse/lib/get-url";
import { buildScene, SCENE_GAMES } from "./game-3d-scenes";

// Tree-shaken three.js r186.1 (MIT), served from the plugin's public folder. The
// version and build (-bN) are in the file name: production caches /plugins for a
// year, so every rebuild needs a new name or browsers keep the old export set.
const THREE_PATH = "/plugins/discourse-rsc/javascripts/rsc-three-0.186.1-b2.js";
let threePromise = null;
let webgl = null;

export function supports3d(game) {
  if (!SCENE_GAMES.has(game)) return false;
  if (webgl === null) {
    try {
      const gl = document.createElement("canvas").getContext("webgl2");
      webgl = !!gl;
      gl?.getExtension("WEBGL_lose_context")?.loseContext();
    } catch {
      webgl = false;
    }
  }
  return webgl;
}

export function loadThree() {
  // A runtime URL keeps the bundler from inlining the library into the forum bundle.
  const url = getURL(THREE_PATH);
  threePromise ??= import(/* webpackIgnore: true */ /* @vite-ignore */ url).catch((e) => {
    threePromise = null;
    throw e;
  });
  return threePromise;
}

export function prefetchThree() {
  if (!supports3d("dice")) return;
  const run = () => loadThree().catch(() => {});
  (window.requestIdleCallback || ((fn) => setTimeout(fn, 800)))(run);
}

export async function createGameScene(game, host, options) {
  if (!supports3d(game)) throw new Error("3D unavailable");
  const T = await loadThree();
  if (!host.isConnected) throw new Error("3D host removed");
  const ctl = buildScene(T, game, host, options);
  await ctl.ready;
  return ctl;
}
