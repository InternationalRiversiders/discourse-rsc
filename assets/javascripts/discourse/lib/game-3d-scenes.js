// WebGL presentation for committed game rounds. Pure module: THREE is injected so
// the library is only downloaded on the games page. Every pose is derived from the
// round id and server state, so a finished animation and a later static view match.
const TAU = Math.PI * 2;
const clamp01 = (t) => Math.max(0, Math.min(1, t));
const lerp = (a, b, t) => a + (b - a) * t;
const easeOutCubic = (t) => 1 - (1 - t) ** 3;
const easeInOutSine = (t) => -(Math.cos(Math.PI * t) - 1) / 2;
const smooth = (t) => t * t * (3 - 2 * t);

export function seeded(seed) {
  let a = (Number(seed) || 7) >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeCanvas(w, h) {
  const c = document.createElement("canvas");
  c.width = w;
  c.height = h;
  return [c, c.getContext("2d")];
}

class Stage {
  constructor(T, host, { fov = 35, exposure = 1, shadows = true } = {}) {
    this.T = T;
    this.host = host;
    const renderer = (this.renderer = new T.WebGLRenderer({ antialias: true, alpha: true, powerPreference: "high-performance" }));
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    renderer.outputColorSpace = T.SRGBColorSpace;
    renderer.toneMapping = T.ACESFilmicToneMapping;
    renderer.toneMappingExposure = exposure;
    renderer.shadowMap.enabled = shadows;
    renderer.shadowMap.type = T.PCFShadowMap;
    renderer.domElement.className = "rg-3d-canvas";
    renderer.domElement.setAttribute("aria-hidden", "true");
    this.scene = new T.Scene();
    this.camera = new T.PerspectiveCamera(fov, 1, 0.1, 100);
    const pmrem = new T.PMREMGenerator(renderer);
    this.env = pmrem.fromScene(studio(T), 0.035).texture;
    pmrem.dispose();
    this.scene.environment = this.env;
    this.tasks = new Set();
    this.frame = 0;
    this.aniso = Math.min(8, renderer.capabilities.getMaxAnisotropy());
    host.appendChild(renderer.domElement);
    this.observer = new ResizeObserver(() => this.resize());
    this.observer.observe(host);
  }
  resize() {
    const w = this.host.clientWidth, h = this.host.clientHeight;
    if (!w || !h || this.disposed) return;
    this.renderer.setSize(w, h, false);
    this.camera.aspect = w / h;
    this.fit?.(w / h);
    this.camera.updateProjectionMatrix();
    this.invalidate();
  }
  texture(canvas, { color = true, repeat = null } = {}) {
    const t = new this.T.CanvasTexture(canvas);
    if (color) t.colorSpace = this.T.SRGBColorSpace;
    t.anisotropy = this.aniso;
    if (repeat) {
      t.wrapS = t.wrapT = this.T.RepeatWrapping;
      t.repeat.set(...repeat);
    }
    return t;
  }
  light({ x = 3, y = 8, z = 4, size = 4, intensity = 2.4, mapSize = 1024 } = {}) {
    const T = this.T;
    this.scene.add(new T.HemisphereLight(0xfff7ea, 0x1c2430, 0.55));
    const key = new T.DirectionalLight(0xfff3e0, intensity);
    key.position.set(x, y, z);
    key.castShadow = true;
    key.shadow.mapSize.set(mapSize, mapSize);
    Object.assign(key.shadow.camera, { left: -size, right: size, top: size, bottom: -size, near: 1, far: 30 });
    key.shadow.bias = -0.0004;
    key.shadow.normalBias = 0.02;
    key.shadow.radius = 4;
    this.scene.add(key);
    return key;
  }
  shadowCatcher(size, opacity = 0.32, y = 0) {
    const T = this.T;
    const plane = new T.Mesh(new T.PlaneGeometry(size, size), new T.ShadowMaterial({ opacity }));
    plane.rotation.x = -Math.PI / 2;
    plane.position.y = y;
    plane.receiveShadow = true;
    this.scene.add(plane);
    return plane;
  }
  invalidate() {
    if (!this.frame && !this.disposed) this.frame = requestAnimationFrame((now) => this.tick(now));
  }
  tick(now) {
    this.frame = 0;
    if (this.disposed) return;
    for (const task of [...this.tasks]) {
      task.start ??= now;
      const t = clamp01((now - task.start) / task.duration);
      task.update(t, now - task.start);
      if (t >= 1) {
        this.tasks.delete(task);
        task.resolve();
      }
    }
    this.renderer.render(this.scene, this.camera);
    if (this.tasks.size) this.invalidate();
  }
  run(duration, update) {
    let task;
    const finished = new Promise((resolve) => (task = { duration, update, resolve }));
    this.tasks.add(task);
    this.invalidate();
    return { finished, cancel: () => this.tasks.delete(task) };
  }
  dispose() {
    this.disposed = true;
    cancelAnimationFrame(this.frame);
    this.observer.disconnect();
    this.tasks.clear();
    const textures = new Set();
    this.scene.traverse((o) => {
      o.geometry?.dispose();
      for (const m of [].concat(o.material || [])) {
        for (const v of Object.values(m)) if (v?.isTexture) textures.add(v);
        m.dispose();
      }
    });
    for (const t of this.extraTextures || []) textures.add(t);
    textures.forEach((t) => t.dispose());
    this.env.dispose();
    this.renderer.dispose();
    this.renderer.forceContextLoss();
    this.renderer.domElement.remove();
  }
}

// Small procedural studio: soft boxes give metal and lacquer something to reflect.
function studio(T) {
  const s = new T.Scene();
  s.add(new T.Mesh(new T.BoxGeometry(24, 24, 24), new T.MeshBasicMaterial({ color: 0x24262c, side: T.BackSide })));
  const panel = (w, h, pos, strength, color = 0xffffff) => {
    const m = new T.Mesh(new T.PlaneGeometry(w, h), new T.MeshBasicMaterial({ color: new T.Color(color).multiplyScalar(strength), side: T.DoubleSide }));
    m.position.set(...pos);
    m.lookAt(0, 0, 0);
    s.add(m);
  };
  panel(12, 5, [0, 11, 1], 4.2);
  panel(5, 9, [-11, 3, 4], 2.2, 0xffe9cc);
  panel(5, 9, [11, 4, -2], 1.6, 0xd6e4ff);
  panel(14, 3, [0, 2, -11], 0.9);
  panel(10, 2, [0, 1.5, 11], 0.7, 0xfff4e0);
  return s;
}

// Box subdivided densely near its edges, then pushed out to a rounded shell.
function roundedBox(T, size, radius) {
  const N = 10, r = radius / size;
  const geo = new T.BoxGeometry(1, 1, 1, N, N, N);
  const p = geo.attributes.position, n = geo.attributes.normal, uv = geo.attributes.uv;
  const remap = (c) => {
    const s = Math.round((c + 0.5) * N);
    if (s <= 4) return -0.5 + (r * s) / 4;
    if (s <= 6) return -0.5 + r + ((1 - 2 * r) * (s - 4)) / 2;
    return 0.5 - r + (r * (s - 6)) / 4;
  };
  const v = new T.Vector3(), q = new T.Vector3(), lim = 0.5 - r;
  for (let i = 0; i < p.count; i++) {
    v.set(remap(p.getX(i)), remap(p.getY(i)), remap(p.getZ(i)));
    q.set(Math.max(-lim, Math.min(lim, v.x)), Math.max(-lim, Math.min(lim, v.y)), Math.max(-lim, Math.min(lim, v.z)));
    v.sub(q).normalize();
    n.setXYZ(i, v.x, v.y, v.z);
    v.multiplyScalar(r).add(q).multiplyScalar(size);
    p.setXYZ(i, v.x, v.y, v.z);
    uv.setXY(i, remap(uv.getX(i) - 0.5) + 0.5, remap(uv.getY(i) - 0.5) + 0.5);
  }
  return geo;
}

function feltTexture(stage, base, speck) {
  const [c, g] = makeCanvas(256, 256);
  g.fillStyle = base;
  g.fillRect(0, 0, 256, 256);
  const rng = seeded(11);
  for (let i = 0; i < 5000; i++) {
    g.fillStyle = rng() > 0.5 ? speck : "#00000018";
    g.fillRect(rng() * 256, rng() * 256, 1, 1 + rng());
  }
  return stage.texture(c, { repeat: [5, 3] });
}

/* ------------------------------------------------------------------ dice */
const DIE_FACES = [3, 4, 1, 6, 2, 5]; // BoxGeometry groups: +x -x +y -y +z -z
const DIE_NORMALS = [[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]];
const PIPS = { 1: [4], 2: [0, 8], 3: [0, 4, 8], 4: [0, 2, 6, 8], 5: [0, 2, 4, 6, 8], 6: [0, 2, 3, 5, 6, 8] };

function dieFace(stage, value, bump) {
  const S = 256, [c, g] = makeCanvas(S, S);
  if (bump) {
    g.fillStyle = "#fff";
  } else {
    const grad = g.createLinearGradient(0, 0, S, S);
    grad.addColorStop(0, "#fffdf6");
    grad.addColorStop(1, "#ece5d3");
    g.fillStyle = grad;
  }
  g.fillRect(0, 0, S, S);
  for (const i of PIPS[value]) {
    const x = S * (0.25 + (i % 3) * 0.25), y = S * (0.25 + Math.floor(i / 3) * 0.25);
    const rad = S * (value === 1 ? 0.12 : 0.082);
    const pip = g.createRadialGradient(x - rad * 0.25, y - rad * 0.3, rad * 0.1, x, y, rad);
    if (bump) {
      pip.addColorStop(0, "#000");
      pip.addColorStop(0.75, "#333");
      pip.addColorStop(1, "#fff");
    } else if (value === 1) {
      pip.addColorStop(0, "#6e1424");
      pip.addColorStop(0.8, "#b8323f");
      pip.addColorStop(1, "#d9a39b");
    } else {
      pip.addColorStop(0, "#0d1718");
      pip.addColorStop(0.8, "#26393a");
      pip.addColorStop(1, "#8b928d");
    }
    g.fillStyle = pip;
    g.beginPath();
    g.arc(x, y, rad, 0, TAU);
    g.fill();
  }
  return stage.texture(c, { color: !bump });
}

function bounceHeight(u, h0) {
  const ends = [0.3, 0.56, 0.75, 0.88, 1], hs = [h0, 0.85, 0.34, 0.11, 0.03];
  if (u < ends[0]) {
    const k = u / ends[0];
    return h0 * (1 - k * k);
  }
  for (let j = 1; j < ends.length; j++) {
    if (u < ends[j]) {
      const k = (u - ends[j - 1]) / (ends[j] - ends[j - 1]);
      return hs[j] * 4 * k * (1 - k);
    }
  }
  return 0;
}

function diceScene(T, host) {
  const stage = new Stage(T, host, { fov: 30, exposure: 1.05 });
  const { scene, camera } = stage;
  stage.light({ x: -2.5, y: 9, z: 4.5, size: 4.5 });
  // Felt tray with lacquered wooden rails.
  const felt = new T.Mesh(new T.PlaneGeometry(7.4, 4.4), new T.MeshStandardMaterial({ map: feltTexture(stage, "#1d554f", "#2c6f66"), roughness: 0.95 }));
  felt.rotation.x = -Math.PI / 2;
  felt.receiveShadow = true;
  scene.add(felt);
  const wood = new T.MeshPhysicalMaterial({ color: 0x5b3420, roughness: 0.38, clearcoat: 0.8, clearcoatRoughness: 0.18 });
  for (const [w, d, x, z] of [[7.9, 0.25, 0, -2.32], [7.9, 0.25, 0, 2.32], [0.25, 4.9, -3.82, 0], [0.25, 4.9, 3.82, 0]]) {
    const rail = new T.Mesh(new T.BoxGeometry(w, 0.32, d), wood);
    rail.position.set(x, 0.16, z);
    rail.castShadow = rail.receiveShadow = true;
    scene.add(rail);
  }
  const geo = roundedBox(T, 1, 0.14);
  const mats = DIE_FACES.map((v) => new T.MeshPhysicalMaterial({ map: dieFace(stage, v), bumpMap: dieFace(stage, v, true), bumpScale: 2.2, roughness: 0.32, clearcoat: 0.55, clearcoatRoughness: 0.25 }));
  const dice = [0, 1, 2].map(() => {
    const m = new T.Mesh(geo, mats);
    m.castShadow = m.receiveShadow = true;
    scene.add(m);
    return m;
  });
  const up = new T.Vector3(0, 1, 0);
  const poses = (round) => {
    const rng = seeded(round?.id ?? 3);
    return (round?.state?.dice || [1, 3, 5]).map((value, i) => {
      const q = new T.Quaternion().setFromUnitVectors(new T.Vector3(...DIE_NORMALS[DIE_FACES.indexOf(value)]), up);
      q.premultiply(new T.Quaternion().setFromAxisAngle(up, (rng() - 0.5) * 1.1));
      return { q, p: new T.Vector3((i - 1) * 1.55 + (rng() - 0.5) * 0.3, 0.5, (rng() - 0.5) * 0.7 + (i === 1 ? -0.25 : 0.2)), rng };
    });
  };
  stage.fit = (aspect) => {
    const k = Math.max(1, 1.45 / aspect);
    camera.position.set(0, 5.4 * k, 4.3 * k);
    camera.lookAt(0, 0, 0.2);
  };
  const place = (round) => poses(round).forEach(({ q, p }, i) => {
    dice[i].quaternion.copy(q);
    dice[i].position.copy(p);
  });
  const extra = new T.Quaternion();
  return {
    stage,
    show(round) {
      place(round);
      stage.invalidate();
    },
    play(round) {
      const end = poses(round), rng = end[0].rng;
      const from = dice.map((d, i) => ({
        p: new T.Vector3(4.6 + i * 0.35, 0.5, 2.9 - i * 0.65),
        h: 2.1 + rng() * 0.7,
        axis: new T.Vector3(rng() - 0.5, rng() - 0.5, rng() - 0.5).normalize(),
        turns: TAU * (2.4 + rng() * 1.2),
      }));
      return stage.run(2000, (t) => dice.forEach((die, i) => {
        const u = clamp01((t - i * 0.05) / 0.88), s = from[i];
        const h = easeOutCubic(clamp01(u / 0.9));
        die.position.set(lerp(s.p.x, end[i].p.x, h), 0.5 + bounceHeight(u, s.h), lerp(s.p.z, end[i].p.z, h));
        extra.setFromAxisAngle(s.axis, s.turns * (1 - u) ** 2.2);
        die.quaternion.copy(end[i].q).multiply(extra);
      }));
    },
  };
}

/* ------------------------------------------------------------------ coin */
function coinFace(stage, label, bump) {
  const S = 1024, [c, g] = makeCanvas(S, S), m = S / 2;
  const tone = (col, b) => (bump ? b : col);
  if (!bump) {
    const grad = g.createRadialGradient(m * 0.7, m * 0.6, 40, m, m, m);
    grad.addColorStop(0, "#fde7a7");
    grad.addColorStop(0.6, "#e0b665");
    grad.addColorStop(1, "#b98a45");
    g.fillStyle = grad;
  } else {
    g.fillStyle = "#777";
  }
  g.fillRect(0, 0, S, S);
  g.strokeStyle = tone("#f6dc9a", "#fff");
  g.lineWidth = 46;
  g.beginPath();
  g.arc(m, m, m - 30, 0, TAU);
  g.stroke();
  g.lineWidth = 10;
  g.strokeStyle = tone("#a77a38", "#444");
  g.beginPath();
  g.arc(m, m, m - 95, 0, TAU);
  g.stroke();
  g.fillStyle = tone("#a47233", "#bbb");
  for (let i = 0; i < 64; i++) {
    const a = (i / 64) * TAU;
    g.beginPath();
    g.arc(m + Math.cos(a) * (m - 118), m + Math.sin(a) * (m - 118), 5, 0, TAU);
    g.fill();
  }
  const arcText = (text, radius, start, step, flip) => {
    g.save();
    g.translate(m, m);
    [...text].forEach((ch, i) => {
      const a = start + i * step;
      g.save();
      g.rotate(a);
      g.translate(0, flip ? radius : -radius);
      g.fillText(ch, 0, 0);
      g.restore();
    });
    g.restore();
  };
  g.font = "bold 62px Georgia, 'Times New Roman', serif";
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillStyle = tone("#8f6127", "#fff");
  arcText("RIVERSIDE", m - 180, -0.82, 0.205, false);
  arcText("RSC", m - 180, 0.205, -0.205, true);
  g.font = "bold 400px 'Songti SC', STSong, 'Noto Serif CJK SC', 'Source Han Serif SC', SimSun, 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', serif";
  g.fillStyle = tone("#7d5320", "#fff");
  g.shadowColor = bump ? "transparent" : "#fff3c455";
  g.shadowOffsetX = -6;
  g.shadowOffsetY = -6;
  g.fillText(label, m, m + 18);
  return stage.texture(c, { color: !bump });
}

function coinScene(T, host) {
  const stage = new Stage(T, host, { fov: 34, exposure: 1.1 });
  const { scene, camera } = stage;
  stage.light({ x: 2.5, y: 9, z: 3, size: 3 });
  stage.shadowCatcher(12, 0.36);
  const [rc, rg] = makeCanvas(32, 512);
  for (let y = 0; y < 512; y += 8) {
    rg.fillStyle = "#fff";
    rg.fillRect(0, y, 32, 4);
    rg.fillStyle = "#555";
    rg.fillRect(0, y + 4, 32, 4);
  }
  const reeded = stage.texture(rc, { color: false });
  reeded.wrapS = reeded.wrapT = T.RepeatWrapping;
  reeded.repeat.set(1, 1);
  reeded.rotation = Math.PI / 2;
  const R = 1.25, H = 0.13;
  const face = (label) => new T.MeshPhysicalMaterial({ map: coinFace(stage, label), bumpMap: coinFace(stage, label, true), bumpScale: 3, metalness: 0.88, roughness: 0.28, clearcoat: 0.35, envMapIntensity: 1.5 });
  const coin = new T.Mesh(new T.CylinderGeometry(R, R, H, 128, 1), [
    new T.MeshStandardMaterial({ color: 0xe2b765, metalness: 0.9, roughness: 0.3, bumpMap: reeded, bumpScale: 2, envMapIntensity: 1.5 }),
    face("正"),
    face("反"),
  ]);
  coin.castShadow = true;
  scene.add(coin);
  const glowTex = (() => {
    const [c, g] = makeCanvas(256, 256);
    const grad = g.createRadialGradient(128, 128, 10, 128, 128, 128);
    grad.addColorStop(0, "#ffffff40");
    grad.addColorStop(1, "#ffffff00");
    g.fillStyle = grad;
    g.fillRect(0, 0, 256, 256);
    return stage.texture(c);
  })();
  const pad = new T.Mesh(new T.CircleGeometry(2.6, 64), new T.MeshBasicMaterial({ map: glowTex, transparent: true, depthWrite: false }));
  pad.rotation.x = -Math.PI / 2;
  pad.position.y = 0.002;
  scene.add(pad);
  const rest = H / 2, flipOf = (round) => (round?.state?.landed === "tails" ? Math.PI : 0);
  // Cap art is drawn with its top toward +X; a quarter turn makes it upright for the camera.
  // Tails is shown by a half turn about X, which also turns its art upside down.
  const yawOf = (round) => Math.PI / 2 + (round?.state?.landed === "tails" ? Math.PI : 0) + (seeded(round?.id ?? 5)() - 0.5) * 0.7;
  const view = { k: 1, mix: 1 };
  const aim = () => {
    // mix 0 = wide toss framing, 1 = close look at the landed face.
    const k = view.k, m = view.mix;
    camera.position.set(0, lerp(3.4, 4.6, m) * k, lerp(6.6, 2.7, m) * k);
    camera.lookAt(0, lerp(1.25, 0, m), 0);
  };
  stage.fit = (aspect) => {
    view.k = Math.max(1, 1.05 / aspect);
    aim();
  };
  const q = new T.Quaternion(), yawQ = new T.Quaternion(), flipQ = new T.Quaternion(), tiltQ = new T.Quaternion();
  const X = new T.Vector3(1, 0, 0), Y = new T.Vector3(0, 1, 0), axis = new T.Vector3();
  const pose = (yaw, flip, tilt = 0, phase = 0, y = rest) => {
    yawQ.setFromAxisAngle(Y, yaw);
    flipQ.setFromAxisAngle(X, flip);
    axis.set(Math.cos(phase), 0, Math.sin(phase));
    tiltQ.setFromAxisAngle(axis, tilt);
    coin.quaternion.copy(q.copy(tiltQ).multiply(yawQ).multiply(flipQ));
    coin.position.set(0, y + Math.sin(Math.abs(tilt)) * R, 0);
  };
  let current = { yaw: 0, flip: 0 };
  return {
    stage,
    show(round) {
      current = { yaw: yawOf(round), flip: flipOf(round) };
      pose(current.yaw, current.flip);
      view.mix = 1;
      aim();
      stage.invalidate();
    },
    play(round) {
      const from = current, flip = flipOf(round), yaw = yawOf(round);
      const spins = Math.round(5 + seeded(round.id)() * 2);
      const end = flip + TAU * spins + (from.flip > flip ? TAU : 0);
      current = { yaw, flip };
      return stage.run(2500, (t) => {
        const air = clamp01(t / 0.7);
        let y = rest, tilt = 0, phase = 0;
        if (t < 0.7) y = rest + 2.55 * 4 * air * (1 - air);
        else if (t < 0.8) {
          const k = (t - 0.7) / 0.1;
          y = rest + 0.16 * 4 * k * (1 - k);
        } else {
          const k = (t - 0.8) / 0.2;
          tilt = 0.16 * (1 - k) ** 2;
          phase = 30 * k * (1 - k * 0.4);
        }
        const spin = lerp(from.flip, end, t < 0.72 ? easeInOutSine(clamp01(t / 0.72)) * 0.12 + clamp01(t / 0.72) * 0.88 : 1);
        pose(lerp(from.yaw, yaw, smooth(clamp01(t / 0.8))), spin, tilt, phase, y);
        view.mix = t < 0.45 ? 1 - smooth(clamp01(t / 0.18)) : smooth(clamp01((t - 0.62) / 0.38));
        aim();
      });
    },
  };
}

/* -------------------------------------------------------------- roulette */
export const WHEEL = [0, 32, 15, 19, 4, 21, 2, 25, 17, 34, 6, 27, 13, 36, 11, 30, 8, 23, 10, 5, 24, 16, 33, 1, 20, 14, 31, 9, 22, 18, 29, 7, 28, 12, 35, 3, 26];
const REDS = new Set([1, 3, 5, 7, 9, 12, 14, 16, 18, 19, 21, 23, 25, 27, 30, 32, 34, 36]);
const POCKET = TAU / 37;
const pocketAngle = (i) => i * POCKET - Math.PI / 2;
const RING_IN = 1.32, RING_MID = 1.78, RING_OUT = 2.18, BALL = 0.085, POCKET_R = 1.56, TRACK_R = 2.62;

function numberRing(stage) {
  const S = 2048, [c, g] = makeCanvas(S, S), m = S / 2, px = m / RING_OUT;
  for (let i = 0; i < 37; i++) {
    const n = WHEEL[i], a = pocketAngle(i);
    const fill = n === 0 ? "#2f8a5c" : REDS.has(n) ? "#a8262f" : "#16191b";
    for (const [r0, r1, col] of [[RING_IN, RING_MID, fill], [RING_MID, RING_OUT, fill]]) {
      g.beginPath();
      g.arc(m, m, r1 * px, a - POCKET / 2, a + POCKET / 2);
      g.arc(m, m, r0 * px, a + POCKET / 2, a - POCKET / 2, true);
      g.closePath();
      g.fillStyle = col;
      g.fill();
    }
    g.save();
    g.translate(m + Math.cos(a) * 1.98 * px, m + Math.sin(a) * 1.98 * px);
    g.rotate(a + Math.PI / 2);
    g.fillStyle = "#f7efdc";
    g.font = "bold 74px Georgia, 'Times New Roman', serif";
    g.textAlign = "center";
    g.textBaseline = "middle";
    g.fillText(String(n), 0, 0);
    g.restore();
  }
  g.strokeStyle = "#e3c27f";
  g.lineWidth = 6;
  for (let i = 0; i < 37; i++) {
    const a = pocketAngle(i) + POCKET / 2;
    g.beginPath();
    g.moveTo(m + Math.cos(a) * RING_MID * px, m + Math.sin(a) * RING_MID * px);
    g.lineTo(m + Math.cos(a) * RING_OUT * px, m + Math.sin(a) * RING_OUT * px);
    g.stroke();
  }
  for (const r of [RING_MID, RING_OUT - 0.01]) {
    g.lineWidth = r === RING_MID ? 10 : 14;
    g.beginPath();
    g.arc(m, m, r * px, 0, TAU);
    g.stroke();
  }
  return stage.texture(c);
}

function surface(r) {
  if (r <= RING_OUT) return 0.24;
  if (r <= TRACK_R) return lerp(0.3, 0.56, (r - RING_OUT) / (TRACK_R - RING_OUT));
  return 0.56 + (r - TRACK_R) * 0.6;
}

function rouletteScene(T, host) {
  const stage = new Stage(T, host, { fov: 32, exposure: 1.05 });
  const { scene, camera } = stage;
  stage.light({ x: 3, y: 10, z: 5, size: 4.2 });
  stage.shadowCatcher(14, 0.35);
  const gold = new T.MeshStandardMaterial({ color: 0xe0b96b, metalness: 1, roughness: 0.22 });
  const lathe = (pts, mat, segs = 128) => {
    const mesh = new T.Mesh(new T.LatheGeometry(pts.map(([r, y]) => new T.Vector2(r, y)), segs), mat);
    mesh.castShadow = mesh.receiveShadow = true;
    return mesh;
  };
  // Static bowl: polished wooden rim and the sloped ball track.
  scene.add(lathe([[3.32, 0], [3.34, 0.62], [3.26, 0.9], [3.12, 0.95], [2.98, 0.84], [2.84, 0.68]], new T.MeshPhysicalMaterial({ color: 0x5a2f1b, roughness: 0.32, clearcoat: 1, clearcoatRoughness: 0.12 })));
  scene.add(lathe([[2.84, 0.68], [TRACK_R + 0.04, 0.58], [TRACK_R - 0.1, 0.5], [RING_OUT + 0.08, 0.3], [RING_OUT + 0.04, 0.14]], new T.MeshPhysicalMaterial({ color: 0x23302d, roughness: 0.42, clearcoat: 0.5 })));
  for (let i = 0; i < 8; i++) {
    const d = new T.Mesh(new T.OctahedronGeometry(0.1, 0), gold);
    const a = (i / 8) * TAU + 0.2;
    d.scale.set(0.7, 0.45, 1.7);
    d.position.set(Math.cos(a) * 2.42, surface(2.42) + 0.03, Math.sin(a) * 2.42);
    d.rotation.y = -a;
    d.castShadow = true;
    scene.add(d);
  }
  // Rotor: everything that turns with the numbers.
  const rotor = new T.Group();
  scene.add(rotor);
  rotor.add(lathe([[0, 0.66], [0.3, 0.62], [0.42, 0.52], [RING_IN, 0.25], [RING_IN, 0.18], [0, 0.18]], new T.MeshPhysicalMaterial({ color: 0x6b3a20, roughness: 0.3, clearcoat: 1, clearcoatRoughness: 0.1 })));
  const ringGeo = new T.RingGeometry(RING_IN, RING_OUT, 148, 1);
  ringGeo.rotateX(-Math.PI / 2);
  const ring = new T.Mesh(ringGeo, new T.MeshPhysicalMaterial({ map: numberRing(stage), roughness: 0.35, clearcoat: 0.7, clearcoatRoughness: 0.15 }));
  ring.position.y = 0.24;
  ring.receiveShadow = true;
  rotor.add(ring);
  rotor.add(lathe([[RING_OUT, 0.24], [RING_OUT + 0.04, 0.3], [RING_OUT + 0.06, 0.12]], gold, 96));
  const fretGeo = new T.BoxGeometry(RING_MID - RING_IN, 0.09, 0.028);
  for (let i = 0; i < 37; i++) {
    const a = pocketAngle(i) + POCKET / 2, f = new T.Mesh(fretGeo, gold);
    f.position.set(Math.cos(a) * (RING_IN + RING_MID) / 2, 0.285, Math.sin(a) * (RING_IN + RING_MID) / 2);
    f.rotation.y = -a;
    f.castShadow = true;
    rotor.add(f);
  }
  const turret = new T.Group();
  turret.add(lathe([[0, 1.15], [0.07, 1.12], [0.09, 0.95], [0.14, 0.7], [0.26, 0.64], [0, 0.64]], gold, 48));
  for (let k = 0; k < 4; k++) {
    const arm = new T.Mesh(new T.CylinderGeometry(0.035, 0.05, 0.85, 16), gold);
    arm.rotation.z = Math.PI / 2;
    arm.position.y = 0.9;
    const holder = new T.Group();
    holder.rotation.y = (k * Math.PI) / 2;
    arm.position.x = 0.42;
    holder.add(arm);
    const knob = new T.Mesh(new T.SphereGeometry(0.07, 20, 12), gold);
    knob.position.set(0.86, 0.9, 0);
    holder.add(knob);
    turret.add(holder);
  }
  turret.traverse((o) => (o.castShadow = true));
  rotor.add(turret);
  const glow = new T.Mesh(new T.RingGeometry(RING_IN + 0.02, RING_OUT - 0.02, 12, 1, 0, POCKET), new T.MeshBasicMaterial({ color: 0xffd98a, transparent: true, opacity: 0, blending: T.AdditiveBlending, depthWrite: false }));
  glow.geometry.rotateX(-Math.PI / 2);
  glow.position.y = 0.247;
  rotor.add(glow);
  const ball = new T.Mesh(new T.SphereGeometry(BALL, 32, 20), new T.MeshPhysicalMaterial({ color: 0xf6f4ee, roughness: 0.12, clearcoat: 1 }));
  ball.castShadow = true;
  scene.add(ball);
  stage.fit = (aspect) => {
    const k = Math.max(1, 1.05 / aspect);
    camera.position.set(0, 8.6 * k, 6.4 * k);
    camera.lookAt(0, 0, 0.18);
  };
  let psi = 0, ballIndex = null;
  const placeBall = (r, rel, lift = 0) => {
    const world = rel - psi; // rotor rotation.y = psi maps rotor angle a to world angle a - psi
    ball.position.set(Math.cos(world) * r, surface(r) + BALL + lift, Math.sin(world) * r);
  };
  const highlight = (index, opacity) => {
    // RingGeometry runs counter-clockwise in XY; after rotateX(-90deg) its angle is negated.
    glow.rotation.y = -(pocketAngle(index) + POCKET / 2);
    glow.material.opacity = opacity;
  };
  return {
    stage,
    show(round) {
      const n = round?.state?.number;
      rotor.rotation.y = psi;
      if (n === undefined || n === null) {
        ballIndex = null;
        placeBall(TRACK_R, -Math.PI / 2 + psi);
        highlight(0, 0);
      } else {
        ballIndex = WHEEL.indexOf(n);
        placeBall(POCKET_R, pocketAngle(ballIndex));
        highlight(ballIndex, 0.42);
      }
      stage.invalidate();
    },
    play(round) {
      const rng = seeded(round.id), index = WHEEL.indexOf(round.state.number), target = pocketAngle(index);
      const psi0 = psi, psi1 = psi0 + TAU * (1.5 + rng() * 0.5);
      const startRel = ballIndex === null ? -Math.PI / 2 + psi0 : pocketAngle(ballIndex);
      const startR = ballIndex === null ? TRACK_R : POCKET_R;
      // Relative angle travels a whole number of turns (minus the ball's lead) to land on target.
      let delta = target - startRel;
      delta = ((delta % TAU) + TAU) % TAU;
      const travel = delta + TAU * (7 + Math.floor(rng() * 2));
      highlight(index, 0);
      return stage.run(5600, (t) => {
        psi = lerp(psi0, psi1, 1 - (1 - t) ** 2.2);
        rotor.rotation.y = psi;
        const rel = startRel + travel * easeOutCubic(clamp01(t / 0.86));
        let r = TRACK_R, lift = 0;
        if (t < 0.08) {
          const k = t / 0.08;
          r = lerp(startR, TRACK_R, smooth(k));
          lift = 0.25 * Math.sin(Math.PI * k);
        } else if (t < 0.5) {
          r = TRACK_R + 0.02 * Math.sin(t * 60);
        } else if (t < 0.68) {
          const k = (t - 0.5) / 0.18;
          r = lerp(TRACK_R, 2.08, k * k);
          lift = 0.13 * Math.max(0, Math.sin(Math.PI * clamp01((k - 0.55) / 0.3)));
        } else if (t < 0.88) {
          const k = (t - 0.68) / 0.2;
          r = lerp(2.08, POCKET_R, smooth(k)) + 0.1 * Math.sin(k * 17) * (1 - k);
          lift = 0.11 * Math.abs(Math.sin(k * Math.PI * 3)) * (1 - k);
        } else {
          r = POCKET_R;
        }
        placeBall(r, rel, lift);
        if (t > 0.9) highlight(index, 0.42 * smooth((t - 0.9) / 0.1));
        if (t >= 1) ballIndex = index;
      });
    },
  };
}

/* ----------------------------------------------------------------- slots */
// Twelve stops, every symbol twice; the visual strip is independent of server odds.
export const REEL = ["seven", "cherry", "bell", "lemon", "diamond", "clover", "seven", "lemon", "cherry", "bell", "clover", "diamond"];
const STOP = TAU / REEL.length;
const CELL = 256;

function drawSymbol(g, name, x, y, s) {
  g.save();
  g.translate(x, y);
  g.scale(s / 200, s / 200);
  g.lineJoin = "round";
  g.lineCap = "round";
  const gloss = (cx, cy, r, inner, outer) => {
    const grad = g.createRadialGradient(cx - r * 0.35, cy - r * 0.4, r * 0.1, cx, cy, r);
    grad.addColorStop(0, inner);
    grad.addColorStop(1, outer);
    return grad;
  };
  if (name === "seven") {
    g.font = "italic 900 190px Georgia, 'Times New Roman', serif";
    g.textAlign = "center";
    g.textBaseline = "middle";
    g.lineWidth = 16;
    g.strokeStyle = "#7a1420";
    g.strokeText("7", 4, 8);
    const grad = g.createLinearGradient(0, -80, 0, 90);
    grad.addColorStop(0, "#ff6a64");
    grad.addColorStop(0.55, "#d3192d");
    grad.addColorStop(1, "#8e0f1c");
    g.fillStyle = grad;
    g.fillText("7", 4, 8);
    g.lineWidth = 5;
    g.strokeStyle = "#ffd77a";
    g.strokeText("7", 4, 8);
  } else if (name === "cherry") {
    g.strokeStyle = "#3b6b22";
    g.lineWidth = 9;
    g.beginPath();
    g.moveTo(-36, 30);
    g.quadraticCurveTo(-20, -40, 22, -70);
    g.moveTo(40, 38);
    g.quadraticCurveTo(36, -20, 22, -70);
    g.stroke();
    g.fillStyle = "#5c9a32";
    g.beginPath();
    g.ellipse(48, -68, 34, 15, -0.4, 0, TAU);
    g.fill();
    for (const [cx, cy] of [[-38, 48], [42, 56]]) {
      g.fillStyle = gloss(cx, cy, 42, "#ff8a8a", "#a3101f");
      g.beginPath();
      g.arc(cx, cy, 42, 0, TAU);
      g.fill();
      g.fillStyle = "#ffffffaa";
      g.beginPath();
      g.ellipse(cx - 14, cy - 16, 9, 6, -0.6, 0, TAU);
      g.fill();
    }
  } else if (name === "lemon") {
    g.fillStyle = gloss(0, 0, 90, "#fff6a1", "#e1b10f");
    g.beginPath();
    g.moveTo(-92, 0);
    g.bezierCurveTo(-70, -78, 70, -78, 92, 0);
    g.bezierCurveTo(70, 78, -70, 78, -92, 0);
    g.fill();
    g.strokeStyle = "#b98a06";
    g.lineWidth = 5;
    g.stroke();
    g.fillStyle = "#ffffff99";
    g.beginPath();
    g.ellipse(-26, -28, 26, 10, -0.3, 0, TAU);
    g.fill();
  } else if (name === "bell") {
    const grad = g.createLinearGradient(-80, 0, 80, 0);
    grad.addColorStop(0, "#b77b12");
    grad.addColorStop(0.35, "#ffe38a");
    grad.addColorStop(0.7, "#e2a521");
    grad.addColorStop(1, "#9c6409");
    g.fillStyle = grad;
    g.beginPath();
    g.moveTo(0, -84);
    g.bezierCurveTo(52, -84, 58, -30, 62, 10);
    g.bezierCurveTo(66, 44, 88, 52, 88, 66);
    g.lineTo(-88, 66);
    g.bezierCurveTo(-88, 52, -66, 44, -62, 10);
    g.bezierCurveTo(-58, -30, -52, -84, 0, -84);
    g.fill();
    g.strokeStyle = "#8a5a06";
    g.lineWidth = 5;
    g.stroke();
    g.fillStyle = "#8a5a06";
    g.beginPath();
    g.arc(0, 80, 18, 0, TAU);
    g.fill();
    g.fillRect(-8, -100, 16, 20);
  } else if (name === "clover") {
    g.fillStyle = "#2f7d32";
    g.fillRect(-6, 20, 12, 80);
    for (const a of [0, 1, 2, 3]) {
      g.save();
      g.rotate(a * (Math.PI / 2) + Math.PI / 4);
      g.fillStyle = gloss(0, -44, 46, "#8fdc76", "#1f7a2c");
      g.beginPath();
      g.moveTo(0, 0);
      g.bezierCurveTo(-60, -30, -46, -92, 0, -66);
      g.bezierCurveTo(46, -92, 60, -30, 0, 0);
      g.fill();
      g.restore();
    }
  } else if (name === "diamond") {
    const pts = [[-86, -26], [-46, -72], [46, -72], [86, -26], [0, 92]];
    g.fillStyle = "#2e7fe0";
    g.beginPath();
    pts.forEach(([px, py], i) => (i ? g.lineTo(px, py) : g.moveTo(px, py)));
    g.closePath();
    g.fill();
    const facets = [[[-86, -26], [-46, -72], [-24, -26]], [[-24, -26], [-46, -72], [46, -72], [24, -26]], [[24, -26], [46, -72], [86, -26]], [[-86, -26], [-24, -26], [0, 92]], [[24, -26], [86, -26], [0, 92]]];
    ["#9fdcff", "#d8f2ff", "#7cc5ff", "#3d94f0", "#1e5fb8"].forEach((col, i) => {
      g.fillStyle = col;
      g.beginPath();
      facets[i].forEach(([px, py], j) => (j ? g.lineTo(px, py) : g.moveTo(px, py)));
      g.closePath();
      g.fill();
    });
    g.strokeStyle = "#ffffffaa";
    g.lineWidth = 3;
    g.stroke();
  }
  g.restore();
}

function reelTexture(stage, blur) {
  // Circumference runs along the canvas width; symbols are drawn rotated so they stand upright.
  const W = CELL * REEL.length, [c, g] = makeCanvas(W, CELL);
  const bg = g.createLinearGradient(0, 0, 0, CELL);
  bg.addColorStop(0, "#efe9f4");
  bg.addColorStop(0.5, "#fffdf8");
  bg.addColorStop(1, "#efe9f4");
  g.fillStyle = bg;
  g.fillRect(0, 0, W, CELL);
  const paint = (offset, alpha) => {
    g.globalAlpha = alpha;
    REEL.forEach((name, i) => {
      for (const wrap of [-W, 0, W]) {
        g.save();
        g.translate((i + 0.5) * CELL + offset + wrap, CELL / 2);
        g.rotate(Math.PI / 2);
        drawSymbol(g, name, 0, 0, CELL * 0.72);
        g.restore();
      }
    });
  };
  if (blur) for (let k = -5; k <= 5; k++) paint(k * 9, 0.16);
  else paint(0, 1);
  g.globalAlpha = 1;
  g.fillStyle = "#d6cde0";
  for (let i = 0; i <= REEL.length; i++) g.fillRect(i * CELL - 1, 0, 2, CELL);
  const t = stage.texture(c);
  t.wrapS = stage.T.RepeatWrapping;
  return t;
}

function slotsScene(T, host) {
  const stage = new Stage(T, host, { fov: 24, exposure: 1.0, shadows: false });
  const { scene, camera } = stage;
  scene.add(new T.HemisphereLight(0xffffff, 0x302a40, 0.8));
  const key = new T.DirectionalLight(0xfff4e6, 2.2);
  key.position.set(0, 1.5, 6);
  scene.add(key);
  const sharp = reelTexture(stage, false), blurred = reelTexture(stage, true);
  stage.extraTextures = [sharp, blurred];
  const R = 1.7, WIDTH = 1.04, GAP = 1.16;
  const reels = [-1, 0, 1].map((k) => {
    const geo = new T.CylinderGeometry(R, R, WIDTH, 96, 1, true);
    geo.rotateZ(Math.PI / 2);
    const mesh = new T.Mesh(geo, new T.MeshStandardMaterial({ map: sharp, roughness: 0.5, metalness: 0 }));
    mesh.position.x = k * GAP;
    scene.add(mesh);
    return mesh;
  });
  const divider = new T.MeshStandardMaterial({ color: 0x18151f, metalness: 0.6, roughness: 0.4 });
  for (const x of [-1.5, -0.5, 0.5, 1.5]) {
    const d = new T.Mesh(new T.CylinderGeometry(R + 0.02, R + 0.02, 0.1, 64), divider);
    d.rotation.z = Math.PI / 2;
    d.position.x = x * GAP;
    scene.add(d);
  }
  stage.fit = (aspect) => {
    const k = Math.max(1, 1.62 / aspect);
    camera.position.set(0, 0, 7.6 * k);
    camera.lookAt(0, 0, 0);
  };
  // Rotation that brings REEL[i] to the front of the reel (verified against rendered frames).
  const angleFor = (i) => (i - 2.5) * STOP + Math.PI / 2;
  const stopsFor = (round) => {
    const rng = seeded(round?.id ?? 9);
    return (round?.state?.symbols || ["seven", "seven", "seven"]).map((name) => {
      const options = REEL.map((n, i) => (n === name ? i : -1)).filter((i) => i >= 0);
      return options[Math.floor(rng() * options.length)];
    });
  };
  const angles = [0, 0, 0];
  return {
    stage,
    show(round) {
      stopsFor(round).forEach((stop, i) => {
        angles[i] = angleFor(stop);
        reels[i].rotation.x = angles[i];
        reels[i].material.map = sharp;
      });
      stage.invalidate();
    },
    play(round) {
      const stops = stopsFor(round), starts = [...angles];
      const durations = [1700, 2150, 2600], total = durations[2];
      const travel = stops.map((stop, i) => {
        const target = angleFor(stop);
        let d = ((starts[i] - target) % TAU + TAU) % TAU;
        return -(d + TAU * (4 + i));
      });
      const last = [...starts];
      return stage.run(total, (t, ms) => reels.forEach((reel, i) => {
        const u = clamp01(ms / durations[i]);
        let a;
        if (u < 0.08) a = starts[i] + 0.22 * Math.sin((Math.PI * u) / 0.08);
        else if (u < 0.9) a = starts[i] + travel[i] * (1 - (1 - (u - 0.08) / 0.82) ** 2.6);
        else {
          const k = (u - 0.9) / 0.1;
          a = starts[i] + travel[i] - STOP * 0.16 * Math.sin(Math.PI * k * 1.5) * (1 - k) ** 1.5;
        }
        if (u >= 1) a = starts[i] + travel[i];
        reel.material.map = Math.abs(a - last[i]) > 0.09 ? blurred : sharp;
        last[i] = a;
        reel.rotation.x = a;
        angles[i] = ((a % TAU) + TAU) % TAU;
      }));
    },
  };
}

const BUILDERS = { dice: diceScene, coin: coinScene, roulette: rouletteScene, slots: slotsScene };
export const SCENE_GAMES = new Set(Object.keys(BUILDERS));

export function buildScene(T, game, host) {
  const ctl = BUILDERS[game](T, host);
  let lastShown;
  return {
    show(round) {
      if (round && lastShown === round.id) return;
      lastShown = round?.id;
      ctl.show(round);
    },
    play(round, { reduced = false } = {}) {
      lastShown = round.id;
      if (reduced) {
        ctl.show(round);
        return { finished: Promise.resolve(), cancel() {} };
      }
      host.dataset.motion = "running";
      const run = ctl.play(round);
      run.finished.then(() => {
        delete host.dataset.motion;
        ctl.show(round);
      });
      return { finished: run.finished, cancel: () => {
        run.cancel();
        delete host.dataset.motion;
        ctl.show(round);
      } };
    },
    resize: () => ctl.stage.resize(),
    dispose: () => ctl.stage.dispose(),
  };
}
