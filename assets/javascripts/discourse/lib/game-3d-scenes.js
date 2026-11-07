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
    renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 1.5));
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
    // Camera framing set by each scene; drift and pointer parallax are layered on top.
    this.view = { pos: new T.Vector3(0, 5, 5), target: new T.Vector3() };
    this.ambient = [];
    this.parallax = 1;
    this.busy = false;
    this.hold = false;
    this.clock = 0;
    this.last = 0;
    this.lastRender = 0;
    this.reduced = !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    this.pointer = { x: 0, y: 0, tx: 0, ty: 0 };
    this.offset = { x: 0, y: 0 };
    this.visible = true;
    host.appendChild(renderer.domElement);
    this.observer = new ResizeObserver(() => this.resize());
    this.observer.observe(host);
    this.io = new IntersectionObserver((entries) => {
      this.visible = entries.some((e) => e.isIntersecting);
      this.invalidate();
    });
    this.io.observe(host);
    this.onVisibility = () => this.invalidate();
    document.addEventListener("visibilitychange", this.onVisibility);
    this.onPointer = (e) => {
      if (e.pointerType === "touch") return;
      const r = host.getBoundingClientRect();
      this.pointer.tx = ((e.clientX - r.left) / r.width - 0.5) * 2;
      this.pointer.ty = ((e.clientY - r.top) / r.height - 0.5) * 2;
      this.invalidate();
    };
    this.onLeave = () => {
      this.pointer.tx = this.pointer.ty = 0;
      this.invalidate();
    };
    host.addEventListener("pointermove", this.onPointer);
    host.addEventListener("pointerleave", this.onLeave);
  }
  setView(pos, target) {
    this.view.pos.set(...pos);
    this.view.target.set(...target);
    this.invalidate();
  }
  get live() {
    return !this.reduced && this.visible && !document.hidden;
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
    // Idle frames (no running animation) are capped near 30 fps.
    if (!this.tasks.size && this.lastRender && now - this.lastRender < 30) {
      this.invalidate();
      return;
    }
    const dt = this.last ? Math.min(0.05, (now - this.last) / 1000) : 0;
    this.last = now;
    this.clock += dt;
    for (const task of [...this.tasks]) {
      task.start ??= now;
      const t = clamp01((now - task.start) / task.duration);
      task.update(t, now - task.start);
      if (t >= 1) {
        this.tasks.delete(task);
        task.resolve();
      }
    }
    for (const fn of this.ambient) fn(dt, this.clock);
    this.applyCamera(dt);
    this.renderer.render(this.scene, this.camera);
    this.lastRender = now;
    const p = this.pointer, settling = Math.abs(p.tx - p.x) + Math.abs(p.ty - p.y) > 0.002;
    if (this.tasks.size || (this.live && this.ambient.length) || settling) this.invalidate();
    else this.last = this.lastRender = 0;
  }
  applyCamera(dt) {
    const T = this.T, cam = this.camera, p = this.pointer, o = this.offset;
    if (!this.hold) {
      const k = 1 - Math.exp(-dt * 3.5);
      p.x += (p.tx - p.x) * k;
      p.y += (p.ty - p.y) * k;
      const drift = this.reduced ? 0 : 1;
      o.x = (p.x * 0.4 + Math.sin(this.clock * 0.31) * 0.14 * drift) * this.parallax;
      o.y = (-p.y * 0.25 + Math.sin(this.clock * 0.23 + 1) * 0.07 * drift) * this.parallax;
    }
    const forward = this._f ||= new T.Vector3(), right = this._r ||= new T.Vector3(), up = this._u ||= new T.Vector3();
    forward.subVectors(this.view.target, this.view.pos).normalize();
    right.crossVectors(forward, cam.up).normalize();
    up.crossVectors(right, forward).normalize();
    const dist = this.view.pos.distanceTo(this.view.target) / 6;
    cam.position.copy(this.view.pos).addScaledVector(right, o.x * dist).addScaledVector(up, o.y * dist);
    cam.lookAt(this.view.target);
  }
  // Gold coins thrown up from `origin` after a win.
  // Coin pool exists from the start (all scaled to zero) so its shader compiles with the scene.
  coinPool() {
    const T = this.T;
    if (!this.coins) {
      const mat = new T.MeshStandardMaterial({ color: 0xf3c65e, metalness: 0.7, roughness: 0.3, emissive: 0x6b4300, emissiveIntensity: 0.55, envMapIntensity: 1.5 });
      this.coins = new T.InstancedMesh(new T.CylinderGeometry(0.13, 0.13, 0.03, 24), mat, 60);
      this.coins.castShadow = true;
      this.coins.frustumCulled = false;
      const zero = new T.Matrix4().makeScale(0, 0, 0);
      for (let i = 0; i < 60; i++) this.coins.setMatrixAt(i, zero);
      this.scene.add(this.coins);
    }
    return this.coins;
  }
  burst(origin, { count = 40, spread = 3.2, lift = 3.4 } = {}) {
    const T = this.T, max = 60;
    this.coinPool();
    const parts = Array.from({ length: Math.min(count, max) }, () => ({
      v: new T.Vector3((Math.random() - 0.5) * spread, lift + Math.random() * 2.6, (Math.random() - 0.5) * spread),
      axis: new T.Vector3(Math.random() - 0.5, Math.random() - 0.5, Math.random() - 0.5).normalize(),
      spin: 6 + Math.random() * 10,
    }));
    const m = new T.Matrix4(), q = new T.Quaternion(), pos = new T.Vector3(), scale = new T.Vector3(), base = new T.Vector3(...origin);
    this.coins.visible = true;
    return this.run(2000, (t, ms) => {
      const sec = ms / 1000;
      for (let i = 0; i < max; i++) {
        const pt = parts[i];
        if (!pt) {
          m.makeScale(0, 0, 0);
        } else {
          pos.copy(base).addScaledVector(pt.v, sec);
          pos.y -= 4.9 * sec * sec;
          q.setFromAxisAngle(pt.axis, pt.spin * sec);
          scale.setScalar(t > 0.75 ? 1 - (t - 0.75) / 0.25 : Math.min(1, t * 12));
          m.compose(pos, q, scale);
        }
        this.coins.setMatrixAt(i, m);
      }
      this.coins.instanceMatrix.needsUpdate = true;
    });
  }
  run(duration, update) {
    let task;
    const finished = new Promise((resolve) => (task = { duration: duration * (this.speed || 1), update, resolve }));
    this.tasks.add(task);
    this.invalidate();
    return { finished, cancel: () => this.tasks.delete(task) };
  }
  dispose() {
    this.disposed = true;
    cancelAnimationFrame(this.frame);
    this.observer.disconnect();
    this.io.disconnect();
    document.removeEventListener("visibilitychange", this.onVisibility);
    this.host.removeEventListener("pointermove", this.onPointer);
    this.host.removeEventListener("pointerleave", this.onLeave);
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
  const { scene } = stage;
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
    stage.setView([0, 5.4 * k, 4.3 * k], [0, 0, 0.2]);
  };
  const place = (round) => poses(round).forEach(({ q, p }, i) => {
    dice[i].quaternion.copy(q);
    dice[i].position.copy(p);
  });
  const extra = new T.Quaternion();
  return {
    stage,
    burstAt: [0, 0.6, 0.2],
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
  g.shadowColor = bump ? "transparent" : "#fff3c466";
  g.shadowOffsetX = -5;
  g.shadowOffsetY = -5;
  drawEmblem(g, label, m, tone("#b8863a", "#fff"), tone("#6b4514", "#ccc"));
  return stage.texture(c, { color: !bump });
}

// Heads: ginkgo leaf. Tails: paper boat on waves. Drawn as raised relief.
function drawEmblem(g, kind, m, fill, line) {
  g.save();
  g.translate(m, m + 6);
  g.scale(0.8, 0.8);
  g.lineJoin = "round";
  g.lineCap = "round";
  if (kind === "heads") {
    g.rotate(-0.18);
    const fan = new Path2D();
    fan.moveTo(0, 95);
    fan.bezierCurveTo(-120, 40, -265, -40, -270, -130);
    fan.bezierCurveTo(-215, -205, -120, -250, -40, -235);
    fan.quadraticCurveTo(-12, -185, 0, -150);
    fan.quadraticCurveTo(12, -185, 40, -235);
    fan.bezierCurveTo(120, -250, 215, -205, 270, -130);
    fan.bezierCurveTo(265, -40, 120, 40, 0, 95);
    fan.closePath();
    g.fillStyle = fill;
    g.fill(fan);
    g.save();
    g.clip(fan);
    g.strokeStyle = line;
    g.globalAlpha = 0.55;
    g.lineWidth = 7;
    for (let a = -1.05; a <= 1.05; a += 0.15) {
      g.beginPath();
      g.moveTo(0, 95);
      g.lineTo(Math.sin(a) * 360, 95 - Math.cos(a) * 360);
      g.stroke();
    }
    g.restore();
    g.strokeStyle = line;
    g.lineWidth = 10;
    g.stroke(fan);
    g.beginPath();
    g.moveTo(0, 90);
    g.bezierCurveTo(4, 170, 30, 230, 70, 270);
    g.lineWidth = 22;
    g.strokeStyle = fill;
    g.stroke();
    g.lineWidth = 6;
    g.strokeStyle = line;
    g.stroke();
  } else {
    const poly = (pts) => {
      const path = new Path2D();
      pts.forEach(([x, y], i) => (i ? path.lineTo(x, y) : path.moveTo(x, y)));
      path.closePath();
      return path;
    };
    const hull = poly([[-300, 40], [300, 40], [200, 175], [-200, 175]]);
    const sail = poly([[-150, 40], [10, -275], [150, 40]]);
    const left = poly([[-300, 40], [-150, 40], [-205, -55]]);
    const right = poly([[300, 40], [150, 40], [205, -55]]);
    for (const [path, alpha] of [[left, 0.8], [right, 0.8], [sail, 1], [hull, 1]]) {
      g.globalAlpha = alpha;
      g.fillStyle = fill;
      g.fill(path);
      g.globalAlpha = 1;
      g.lineWidth = 9;
      g.strokeStyle = line;
      g.stroke(path);
    }
    g.lineWidth = 6;
    g.beginPath();
    g.moveTo(10, -275);
    g.lineTo(0, 40);
    g.moveTo(-200, 175);
    g.lineTo(-150, 40);
    g.moveTo(200, 175);
    g.lineTo(150, 40);
    g.stroke();
    g.lineWidth = 12;
    for (const [y, w] of [[230, 330], [285, 230]]) {
      g.beginPath();
      for (let x = -w; x <= w; x += 4) {
        const yy = y + Math.sin((x / w) * Math.PI * 3) * 14;
        x === -w ? g.moveTo(x, yy) : g.lineTo(x, yy);
      }
      g.stroke();
    }
  }
  g.restore();
}

function coinScene(T, host) {
  const stage = new Stage(T, host, { fov: 34, exposure: 1.1 });
  const { scene } = stage;
  const key = stage.light({ x: 2.5, y: 9, z: 3, size: 3 });
  stage.shadowCatcher(12, 0.36);
  // Idle: the key light circles slowly so highlights slide across the metal.
  let lightAngle = 0.9;
  stage.ambient.push((dt) => {
    lightAngle += dt * 0.45;
    key.position.set(Math.cos(lightAngle) * 3.5, 9, Math.sin(lightAngle) * 3.5);
  });
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
    face("heads"),
    face("tails"),
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
    stage.setView([0, lerp(3.4, 4.6, m) * k, lerp(6.6, 2.7, m) * k], [0, lerp(1.25, 0, m), 0]);
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
    burstAt: [0, 0.3, 0],
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
  const { scene } = stage;
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
    stage.setView([0, 8.6 * k, 6.4 * k], [0, 0, 0.18]);
  };
  let psi = 0, ballIndex = null;
  // Idle: the rotor keeps turning slowly; a settled ball rides in its pocket.
  stage.ambient.push((dt) => {
    if (stage.busy) return;
    psi += dt * 0.22;
    rotor.rotation.y = psi;
    if (ballIndex === null) placeBall(TRACK_R, -Math.PI / 2 + psi);
    else placeBall(POCKET_R, pocketAngle(ballIndex));
  });
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
    burstAt: [0, 0.9, 0],
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
  const { scene } = stage;
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
    stage.setView([0, 0, 7.6 * k], [0, 0, 0]);
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
  stage.parallax = 0.35;
  return {
    stage,
    burstAt: [0, -1.9, 2.4],
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


/* ------------------------------------------------------------- blackjack */
const SUIT_GLYPHS = ["♠", "♥", "♣", "♦"];
const RANK_LABELS = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"];
const CARD_W = 0.92, CARD_H = 1.3;

function roundRect(g, x, y, w, h, r) {
  g.beginPath();
  g.moveTo(x + r, y);
  g.arcTo(x + w, y, x + w, y + h, r);
  g.arcTo(x + w, y + h, x, y + h, r);
  g.arcTo(x, y + h, x, y, r);
  g.arcTo(x, y, x + w, y, r);
  g.closePath();
}

function cardCanvas(n) {
  const W = 256, H = 362, [c, g] = makeCanvas(W, H);
  roundRect(g, 3, 3, W - 6, H - 6, 22);
  if (n === null || n === undefined) {
    g.fillStyle = "#f4efe4";
    g.fill();
    roundRect(g, 16, 16, W - 32, H - 32, 14);
    const grad = g.createLinearGradient(0, 0, W, H);
    grad.addColorStop(0, "#3f4c80");
    grad.addColorStop(1, "#283258");
    g.fillStyle = grad;
    g.fill();
    g.save();
    g.clip();
    g.strokeStyle = "#ffffff1f";
    g.lineWidth = 3;
    for (let i = -H; i < W + H; i += 14) {
      g.beginPath();
      g.moveTo(i, 0);
      g.lineTo(i + H, H);
      g.moveTo(i + H, 0);
      g.lineTo(i, H);
      g.stroke();
    }
    g.restore();
    g.fillStyle = "#e9d6a3";
    g.beginPath();
    g.arc(W / 2, H / 2, 46, 0, TAU);
    g.fill();
    g.fillStyle = "#2c3660";
    g.font = "bold 58px Georgia, serif";
    g.textAlign = "center";
    g.textBaseline = "middle";
    g.fillText("R", W / 2, H / 2 + 3);
    return c;
  }
  const grad = g.createLinearGradient(0, 0, W, H);
  grad.addColorStop(0, "#fffdf8");
  grad.addColorStop(1, "#eee8dc");
  g.fillStyle = grad;
  g.fill();
  g.strokeStyle = "#d7d0c2";
  g.lineWidth = 3;
  g.stroke();
  const suit = Math.floor(n / 13), red = suit === 1 || suit === 3;
  const rank = RANK_LABELS[n % 13], glyph = SUIT_GLYPHS[suit];
  g.fillStyle = red ? "#b4323f" : "#1f2a33";
  const corner = () => {
    g.textAlign = "center";
    g.textBaseline = "alphabetic";
    g.font = `bold ${rank === "10" ? 50 : 60}px Georgia, 'Times New Roman', serif`;
    g.fillText(rank, 42, 70);
    g.font = "44px 'Segoe UI Symbol', 'Apple Symbols', 'DejaVu Sans', sans-serif";
    g.fillText(glyph, 42, 118);
  };
  corner();
  g.save();
  g.translate(W, H);
  g.rotate(Math.PI);
  corner();
  g.restore();
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.font = `${n % 13 >= 10 ? 120 : 150}px 'Segoe UI Symbol', 'Apple Symbols', 'DejaVu Sans', sans-serif`;
  if (n % 13 >= 10) {
    roundRect(g, 66, 96, W - 132, H - 192, 10);
    g.lineWidth = 4;
    g.strokeStyle = red ? "#b4323f88" : "#1f2a3388";
    g.stroke();
    g.font = "bold 92px Georgia, serif";
    g.fillText(rank, W / 2, H / 2 - 16);
    g.font = "60px 'Segoe UI Symbol', 'Apple Symbols', 'DejaVu Sans', sans-serif";
    g.fillText(glyph, W / 2, H / 2 + 56);
  } else {
    g.fillText(glyph, W / 2, H / 2 + 6);
  }
  return c;
}

function tableCanvas() {
  // 12 x 8 world units; canvas down = +Z. Table: straight dealer edge, curved player edge.
  const k = 170, W = 12 * k, H = 8 * k, [c, g] = makeCanvas(W, H);
  const cx = 6 * k, cz = (2.6 - 3.6 + 3.6) * k, R = 5.2 * k; // arc centre at world z = -1.0
  const shape = () => {
    g.beginPath();
    g.moveTo(cx - R, cz - 2.6 * k + 0.0);
    g.lineTo(cx + R, cz - 2.6 * k);
    g.lineTo(cx + R, cz);
    g.arc(cx, cz, R, 0, Math.PI);
    g.closePath();
  };
  shape();
  const felt = g.createRadialGradient(cx, cz, 0.4 * k, cx, cz, R);
  felt.addColorStop(0, "#2a7a62");
  felt.addColorStop(1, "#14483b");
  g.fillStyle = felt;
  g.fill();
  g.save();
  g.clip();
  const rng = seeded(21);
  for (let i = 0; i < 26000; i++) {
    g.fillStyle = rng() > 0.5 ? "#ffffff0d" : "#0000001a";
    g.fillRect(rng() * W, rng() * H, 2, 2);
  }
  g.restore();
  g.strokeStyle = "#e3c27f";
  g.lineWidth = 5;
  g.beginPath();
  g.arc(cx, cz, 3.25 * k, 0.18 * Math.PI, 0.82 * Math.PI);
  g.stroke();
  const arcText = (text, radius, size, color) => {
    g.save();
    g.translate(cx, cz);
    g.font = `bold ${size}px Georgia, 'Songti SC', 'Noto Serif CJK SC', serif`;
    g.fillStyle = color;
    g.textAlign = "center";
    g.textBaseline = "middle";
    const chars = [...text], step = (size * 0.78) / radius;
    chars.forEach((ch, i) => {
      const a = Math.PI / 2 + (chars.length / 2 - i - 0.5) * step;
      g.save();
      g.rotate(a - Math.PI / 2);
      g.translate(0, radius);
      g.fillText(ch, 0, 0);
      g.restore();
    });
    g.restore();
  };
  arcText("TWENTY · ONE", 3.55 * k, 70, "#f0d796");
  arcText("庄家软 17 点停牌", 3.0 * k, 46, "#cfe6d7cc");
  g.strokeStyle = "#f0d79699";
  g.lineWidth = 6;
  g.beginPath();
  g.arc(cx - 2.15 * k, cz + 2.25 * k, 0.55 * k, 0, TAU);
  g.stroke();
  return c;
}

function blackjackScene(T, host) {
  const stage = new Stage(T, host, { fov: 34, exposure: 1.05 });
  const { scene } = stage;
  stage.light({ x: -2, y: 10, z: 4, size: 5.5, mapSize: 2048 });
  const tableTex = stage.texture(tableCanvas());
  const table = new T.Mesh(new T.PlaneGeometry(12, 8), new T.MeshStandardMaterial({ map: tableTex, roughness: 0.92, alphaTest: 0.5 }));
  table.rotation.x = -Math.PI / 2;
  table.position.z = 0.4;
  table.receiveShadow = true;
  scene.add(table);
  const railGeo = new T.TorusGeometry(5.2, 0.17, 14, 120, Math.PI);
  railGeo.rotateX(Math.PI / 2);
  const leather = new T.MeshPhysicalMaterial({ color: 0x3a1f16, roughness: 0.42, clearcoat: 0.7, clearcoatRoughness: 0.3 });
  const rail = new T.Mesh(railGeo, leather);
  rail.position.set(0, 0.14, -1.0);
  rail.castShadow = rail.receiveShadow = true;
  scene.add(rail);
  // Card shoe on the dealer's right.
  const SHOE = new T.Vector3(3.35, 0.55, -2.35);
  const shoe = new T.Mesh(new T.BoxGeometry(1.15, 0.5, 1.6), new T.MeshPhysicalMaterial({ color: 0x5c1f24, roughness: 0.3, clearcoat: 1 }));
  shoe.position.set(3.4, 0.25, -2.5);
  shoe.rotation.y = -0.35;
  shoe.castShadow = shoe.receiveShadow = true;
  scene.add(shoe);
  const cache = new Map(), extra = (stage.extraTextures = []);
  const material = (n) => {
    const id = n ?? "back";
    if (!cache.has(id)) {
      const tex = stage.texture(cardCanvas(n));
      extra.push(tex);
      cache.set(id, new T.MeshStandardMaterial({ map: tex, roughness: 0.42, alphaTest: 0.5 }));
    }
    return cache.get(id);
  };
  const faceGeo = new T.PlaneGeometry(CARD_W, CARD_H);
  faceGeo.rotateX(-Math.PI / 2);
  const backGeo = new T.PlaneGeometry(CARD_W, CARD_H);
  backGeo.rotateX(Math.PI / 2);
  const makeCard = (n) => {
    const g = new T.Group(), front = new T.Mesh(faceGeo, material(n)), back = new T.Mesh(backGeo, material(null));
    front.position.y = 0.002;
    back.position.y = -0.002;
    front.castShadow = back.castShadow = true;
    g.add(front, back);
    g.userData = { front, value: n };
    scene.add(g);
    return g;
  };
  const setFace = (card, n) => {
    card.userData.front.material = material(n);
    card.userData.value = n;
  };
  // Chips in the betting circle.
  const chipGeo = new T.CylinderGeometry(0.3, 0.3, 0.07, 40);
  const chipMats = [0xb8313f, 0x2f6fb5, 0x2a8a5a].map((color) => new T.MeshStandardMaterial({ color, roughness: 0.4, metalness: 0.1 }));
  // Side: white edge spots on the chip colour, painted once.
  const chipEdge = (() => {
    const [c, g] = makeCanvas(256, 16);
    g.fillStyle = "#8d2430";
    g.fillRect(0, 0, 256, 16);
    g.fillStyle = "#f4efe4";
    for (let x = 0; x < 256; x += 32) g.fillRect(x, 0, 14, 16);
    return new T.MeshStandardMaterial({ map: stage.texture(c), roughness: 0.45 });
  })();
  const chips = new T.Group();
  scene.add(chips);
  const setChips = (round) => {
    chips.clear();
    if (!round) return;
    const stake = Number(round.stake) || 0, count = Math.max(1, Math.min(8, Math.ceil(Math.log2(stake + 1))));
    const stacks = round.state?.doubled ? 2 : 1;
    for (let s = 0; s < stacks; s++) {
      for (let i = 0; i < count; i++) {
        const chip = new T.Mesh(chipGeo, [chipEdge, chipMats[(i + s) % 3], chipMats[(i + s) % 3]]);
        chip.position.set(-2.15 + s * 0.68, 0.036 + i * 0.072, 1.25 + (s ? 0.12 : 0));
        chip.rotation.y = i * 0.7;
        chip.castShadow = chip.receiveShadow = true;
        chips.add(chip);
      }
    }
  };
  const slot = (who, i, id) => {
    const rng = seeded((Number(id) || 1) * 31 + i * 7 + (who === "dealer" ? 3 : 0));
    return {
      pos: new T.Vector3(-0.32 + i * 0.6, 0.004 + i * 0.006, (who === "dealer" ? -1.25 : 1.0) + (rng() - 0.5) * 0.06),
      yaw: (rng() - 0.5) * 0.12,
    };
  };
  let shown = { id: null, player: [], dealer: [] };
  const clearTable = () => {
    for (const card of [...shown.player, ...shown.dealer]) scene.remove(card);
  };
  const place = (card, s, faceUp) => {
    card.visible = true;
    card.position.copy(s.pos);
    card.rotation.set(0, s.yaw, faceUp ? 0 : Math.PI);
  };
  stage.fit = (aspect) => {
    const k = Math.max(1, 1.4 / aspect);
    stage.setView([0, 6.4 * k, 4.6 * k], [0, 0, -0.05]);
  };
  return {
    stage,
    burstAt: [0, 0.5, 0.6],
    show(round) {
      clearTable();
      const state = round?.state || { player: [0, 22], dealer: [11, null] };
      shown = { id: round?.id ?? null, player: [], dealer: [] };
      for (const who of ["player", "dealer"]) {
        (state[who] || []).forEach((n, i) => {
          const card = makeCard(n);
          place(card, slot(who, i, round?.id), n !== null);
          shown[who].push(card);
        });
      }
      setChips(round);
      stage.invalidate();
    },
    play(round) {
      const state = round.state, steps = [];
      const fresh = shown.id !== round.id;
      const leaving = fresh ? [...shown.player, ...shown.dealer] : [];
      let t = 0;
      if (leaving.length) {
        steps.push({ kind: "sweep", cards: leaving, start: 0, dur: 450, from: leaving.map((c) => c.position.clone()) });
        t = 380;
      }
      const next = fresh ? { id: round.id, player: [], dealer: [] } : shown;
      const deal = (who, i, faceUp) => {
        const n = state[who][i];
        const card = makeCard(faceUp ? n : null);
        card.visible = false;
        next[who][i] = card;
        steps.push({ kind: "deal", card, to: slot(who, i, round.id), faceUp, start: t, dur: 560 });
        t += 400;
      };
      if (fresh) {
        setChips(round);
        for (const [who, i] of [["player", 0], ["dealer", 0], ["player", 1], ["dealer", 1]]) {
          if (state[who].length > i) deal(who, i, who === "player" || i === 0);
        }
      } else {
        setChips(round);
      }
      for (let i = fresh ? 2 : next.player.length; i < state.player.length; i++) deal("player", i, true);
      const hole = next.dealer[1];
      if (hole && state.dealer[1] !== null && hole.userData.value === null) {
        steps.push({ kind: "flip", card: hole, n: state.dealer[1], to: slot("dealer", 1, round.id), start: t + 120, dur: 620 });
        t += 760;
      }
      for (let i = Math.max(2, fresh ? 2 : next.dealer.length); i < state.dealer.length; i++) deal("dealer", i, true);
      shown = next;
      const total = Math.max(500, t + 200);
      return stage.run(total, (u, ms) => {
        for (const step of steps) {
          const k = clamp01((ms / (stage.speed || 1) - step.start) / step.dur);
          if (step.kind === "sweep") {
            step.cards.forEach((card, j) => {
              const e = k * k;
              card.position.set(lerp(step.from[j].x, -6.5, e), step.from[j].y + Math.sin(Math.PI * k) * 0.4, lerp(step.from[j].z, -2.6, e));
              card.rotation.y += 0.02;
              if (k >= 1 && card.parent) scene.remove(card);
            });
          } else if (step.kind === "deal") {
            const { card, to, faceUp } = step;
            if (k <= 0) continue;
            card.visible = true;
            const e = easeOutCubic(k);
            card.position.lerpVectors(SHOE, to.pos, e);
            card.position.y += Math.sin(Math.PI * k) * 0.55;
            card.rotation.set(0, lerp(-0.9, to.yaw, e), faceUp ? lerp(Math.PI, 0, smooth(clamp01((k - 0.15) / 0.75))) : Math.PI);
          } else if (step.kind === "flip") {
            if (k <= 0) continue;
            if (step.card.userData.value === null) setFace(step.card, step.n);
            const e = smooth(k);
            step.card.position.copy(step.to.pos);
            step.card.position.y += Math.sin(Math.PI * k) * 0.45;
            step.card.position.x += Math.sin(Math.PI * k) * 0.15;
            step.card.rotation.set(0, step.to.yaw, lerp(Math.PI, 0, e));
          }
        }
      });
    },
  };
}

/* --------------------------------------------------------------- scratch */
// Ticket art in canvas pixels; 200 px = 1 world unit.
const TICKET = { W: 1080, H: 1420, unit: 200 };
const SPOT_RECTS = Array.from({ length: 10 }, (_, i) => {
  const col = i % 2, row = Math.floor(i / 2), cw = 468, ch = 184;
  const x = 60 + col * (cw + 24), y = 330 + row * (ch + 20);
  return { x, y, w: cw, h: ch, face: { x: x + 16, y: y + 46, w: cw - 32, h: ch - 62 } };
});

function drawTicket(g, data) {
  const { W, H } = TICKET;
  g.clearRect(0, 0, W, H);
  roundRect(g, 4, 4, W - 8, H - 8, 44);
  const bg = g.createLinearGradient(0, 0, W, H);
  bg.addColorStop(0, "#f8ecd0");
  bg.addColorStop(0.5, "#f1dfb2");
  bg.addColorStop(1, "#e9d39e");
  g.fillStyle = bg;
  g.fill();
  g.lineWidth = 6;
  g.strokeStyle = "#fff6dc";
  g.stroke();
  roundRect(g, 26, 26, W - 52, H - 52, 30);
  g.setLineDash([14, 10]);
  g.lineWidth = 3;
  g.strokeStyle = "#c4aa72";
  g.stroke();
  g.setLineDash([]);
  g.fillStyle = "#8b7248";
  g.font = "600 30px Georgia, serif";
  g.textBaseline = "middle";
  g.textAlign = "left";
  g.fillText("R I V E R S I D E", 64, 86);
  g.textAlign = "right";
  g.font = "bold 40px Georgia, sans-serif";
  g.fillStyle = "#735b32";
  g.fillText(`${data.price} RSC`, W - 64, 86);
  g.textAlign = "left";
  g.font = "bold 92px 'Songti SC', 'Noto Serif CJK SC', 'Source Han Serif SC', serif";
  const title = g.createLinearGradient(0, 140, 0, 240);
  title.addColorStop(0, "#9a5a1c");
  title.addColorStop(1, "#5d3810");
  g.fillStyle = title;
  g.fillText("刮卡寻宝", 60, 196);
  g.textAlign = "right";
  g.font = "600 36px 'PingFang SC', 'Noto Sans CJK SC', sans-serif";
  g.fillStyle = "#a0632a";
  g.fillText("十重好运", W - 64, 200);
  g.textAlign = "left";
  g.font = "34px 'PingFang SC', 'Noto Sans CJK SC', sans-serif";
  g.fillStyle = "#856d42";
  g.fillText(`10 个开奖位 · 每位 ${data.unit} RSC`, 62, 278);
  SPOT_RECTS.forEach((r, i) => {
    const spot = data.spots[i] || {};
    roundRect(g, r.x, r.y, r.w, r.h, 20);
    g.fillStyle = "#eddbb1";
    g.fill();
    g.strokeStyle = "#d4bd85";
    g.lineWidth = 3;
    g.stroke();
    g.fillStyle = "#8b7248";
    g.font = "bold 28px monospace";
    g.textAlign = "left";
    g.fillText(String(i + 1).padStart(2, "0"), r.x + 18, r.y + 26);
    const f = r.face;
    roundRect(g, f.x, f.y, f.w, f.h, 12);
    if (spot.won) {
      const glow = g.createRadialGradient(f.x + f.w / 2, f.y, 10, f.x + f.w / 2, f.y + f.h / 2, f.w / 1.6);
      glow.addColorStop(0, "#fff9df");
      glow.addColorStop(1, "#f4d278");
      g.fillStyle = glow;
    } else {
      g.fillStyle = "#fbf3da";
    }
    g.fill();
    g.textAlign = "center";
    const cx = f.x + f.w / 2, cy = f.y + f.h / 2;
    if (!data.purchased) {
      g.fillStyle = "#c9b27c";
      g.font = "64px serif";
      g.fillText("✦", cx, cy + 4);
    } else if (spot.won) {
      g.fillStyle = "#85420e";
      g.font = "bold 62px Georgia, sans-serif";
      g.fillText(`${spot.payout} RSC`, cx, cy - 14);
      g.font = "30px 'PingFang SC', 'Noto Sans CJK SC', sans-serif";
      g.fillStyle = "#9a6a2a";
      g.fillText(`${spot.multiplier} 倍`, cx, cy + 34);
    } else {
      g.fillStyle = "#9b8a68";
      g.font = "600 46px 'PingFang SC', 'Noto Sans CJK SC', sans-serif";
      g.fillText("未中奖", cx, cy - 10);
      g.font = "30px sans-serif";
      g.fillText("0 RSC", cx, cy + 34);
    }
  });
  g.textAlign = "left";
  g.fillStyle = "#a08a5e";
  g.font = "22px monospace";
  g.fillText(`No. ${String(data.serial || 0).padStart(8, "0")}`, 62, H - 72);
  const rng = seeded(data.serial || 3);
  for (let x = W - 360; x < W - 64; x += 4 + Math.floor(rng() * 5)) g.fillRect(x, H - 96, 1 + Math.floor(rng() * 3), 46);
}

function drawFoil(g, spotIndex, rng) {
  const f = SPOT_RECTS[spotIndex].face;
  g.save();
  roundRect(g, f.x - 2, f.y - 2, f.w + 4, f.h + 4, 13);
  g.clip();
  const foil = g.createLinearGradient(f.x, f.y, f.x + f.w, f.y + f.h);
  foil.addColorStop(0, "#d9dde2");
  foil.addColorStop(0.35, "#f7f8fa");
  foil.addColorStop(0.55, "#aeb6c0");
  foil.addColorStop(1, "#e3e7ec");
  g.fillStyle = foil;
  g.fillRect(f.x - 2, f.y - 2, f.w + 4, f.h + 4);
  for (let i = 0; i < 900; i++) {
    g.fillStyle = rng() > 0.5 ? "#ffffff70" : "#6c768230";
    g.fillRect(f.x + rng() * f.w, f.y + rng() * f.h, 2, 2);
  }
  g.strokeStyle = "#ffffff55";
  g.lineWidth = 2;
  for (let x = f.x - f.h; x < f.x + f.w; x += 22) {
    g.beginPath();
    g.moveTo(x, f.y + f.h);
    g.lineTo(x + f.h, f.y);
    g.stroke();
  }
  g.fillStyle = "#5d6773";
  g.font = "600 40px 'PingFang SC', 'Noto Sans CJK SC', sans-serif";
  g.textAlign = "center";
  g.textBaseline = "middle";
  g.fillText("刮开好运", f.x + f.w / 2, f.y + f.h / 2);
  g.restore();
}

function scratchScene(T, host, { onSpot = () => {} } = {}) {
  const stage = new Stage(T, host, { fov: 28, exposure: 1.02 });
  const { scene, camera } = stage;
  stage.parallax = 0.5;
  stage.light({ x: 3, y: 6, z: 9, size: 6, intensity: 2.1 });
  const { W, H, unit } = TICKET, w = W / unit, h = H / unit;
  const [baseCanvas, base] = makeCanvas(W, H), coatCanvas = document.createElement("canvas");
  coatCanvas.width = W;
  coatCanvas.height = H;
  const coat = coatCanvas.getContext("2d", { willReadFrequently: true });
  const baseTex = stage.texture(baseCanvas), coatTex = stage.texture(coatCanvas);
  const ticket = new T.Group();
  scene.add(ticket);
  const front = new T.Mesh(new T.PlaneGeometry(w, h), new T.MeshStandardMaterial({ map: baseTex, roughness: 0.75, alphaTest: 0.5 }));
  const backGeo = new T.PlaneGeometry(w, h);
  backGeo.rotateY(Math.PI);
  const back = new T.Mesh(backGeo, new T.MeshStandardMaterial({ color: 0xe6d3a4, roughness: 0.8, alphaMap: baseTex, alphaTest: 0.5 }));
  const foil = new T.Mesh(new T.PlaneGeometry(w, h), new T.MeshStandardMaterial({ map: coatTex, transparent: true, metalness: 0.75, roughness: 0.32, envMapIntensity: 1.4, depthWrite: false }));
  foil.position.z = 0.004;
  front.castShadow = true;
  ticket.add(front, back, foil);
  const shadow = stage.shadowCatcher(30, 0.28, 0);
  shadow.rotation.x = 0;
  shadow.position.z = -0.6;
  // Glows for winning spots, pulsing once revealed.
  const glowTex = (() => {
    const [c, g] = makeCanvas(128, 128);
    const grad = g.createRadialGradient(64, 64, 4, 64, 64, 64);
    grad.addColorStop(0, "#ffe39acc");
    grad.addColorStop(1, "#ffe39a00");
    g.fillStyle = grad;
    g.fillRect(0, 0, 128, 128);
    return stage.texture(c);
  })();
  const glows = SPOT_RECTS.map((r) => {
    const m = new T.Mesh(new T.PlaneGeometry((r.w / unit) * 1.25, (r.h / unit) * 1.6), new T.MeshBasicMaterial({ map: glowTex, transparent: true, opacity: 0, blending: T.AdditiveBlending, depthWrite: false }));
    m.position.set((r.x + r.w / 2) / unit - w / 2, h / 2 - (r.y + r.h / 2) / unit, 0.02);
    m.visible = false;
    ticket.add(m);
    return m;
  });
  // Foil flakes.
  const FLAKES = 160;
  const flakes = new T.InstancedMesh(new T.PlaneGeometry(0.06, 0.04), new T.MeshStandardMaterial({ color: 0xd8dde3, metalness: 0.8, roughness: 0.3, side: T.DoubleSide }), FLAKES);
  flakes.frustumCulled = false;
  scene.add(flakes);
  const flakeState = Array.from({ length: FLAKES }, () => ({ life: 0, p: new T.Vector3(), v: new T.Vector3(), spin: new T.Vector3() }));
  let flakeCursor = 0;
  const zero = new T.Matrix4().makeScale(0, 0, 0), m4 = new T.Matrix4(), q = new T.Quaternion(), e = new T.Euler(), sc = new T.Vector3(1, 1, 1);
  for (let i = 0; i < FLAKES; i++) flakes.setMatrixAt(i, zero);
  const spawn = (point, n) => {
    for (let i = 0; i < n; i++) {
      const f = flakeState[flakeCursor++ % FLAKES];
      f.life = 1;
      f.p.copy(point);
      f.v.set((Math.random() - 0.5) * 1.6, Math.random() * 1.2, 0.6 + Math.random() * 0.9);
      f.spin.set(Math.random() * 12, Math.random() * 12, Math.random() * 12);
    }
  };
  let data = { purchased: false, spots: [], price: "0", unit: "0", serial: 0 };
  let opened = new Set(), revealing = new Set(), entering = 0, flying = false;
  stage.ambient.push((dt, clock) => {
    if (!stage.hold && !flying) {
      ticket.position.y = Math.sin(clock * 0.9) * 0.05;
      ticket.rotation.x = -0.1 + Math.sin(clock * 0.6) * 0.025 - stage.pointer.y * 0.06;
      ticket.rotation.y = Math.sin(clock * 0.45) * 0.035 + stage.pointer.x * 0.1;
    }
    let alive = false;
    flakeState.forEach((f, i) => {
      if (f.life <= 0) return;
      alive = true;
      f.life -= dt * 0.9;
      f.v.y -= 6 * dt;
      f.p.addScaledVector(f.v, dt);
      e.set(f.spin.x * f.life, f.spin.y * f.life, f.spin.z * f.life);
      q.setFromEuler(e);
      sc.setScalar(Math.max(0, f.life));
      m4.compose(f.p, q, sc);
      flakes.setMatrixAt(i, f.life > 0 ? m4 : zero);
    });
    if (alive) flakes.instanceMatrix.needsUpdate = true;
    glows.forEach((g, i) => {
      if (!g.visible) return;
      g.material.opacity = 0.35 + Math.sin(clock * 3 + i) * 0.2;
    });
  });
  const paintAll = () => {
    drawTicket(base, data);
    coat.clearRect(0, 0, W, H);
    if (data.purchased) {
      const rng = seeded(data.serial || 5);
      SPOT_RECTS.forEach((_, i) => !opened.has(i) && drawFoil(coat, i, rng));
    }
    baseTex.needsUpdate = coatTex.needsUpdate = true;
    glows.forEach((g, i) => {
      g.visible = data.purchased && opened.has(i) && !!data.spots[i]?.won;
    });
    stage.invalidate();
  };
  const coverage = (i) => {
    const f = SPOT_RECTS[i].face;
    const px = coat.getImageData(f.x, f.y, f.w, f.h).data;
    let clear = 0, total = 0;
    for (let k = 3; k < px.length; k += 32) {
      total++;
      if (px[k] < 128) clear++;
    }
    return total ? clear / total : 1;
  };
  // Remaining foil on a spot dissolves outward, then the spot counts as opened.
  const dissolve = (i, delay = 0) => {
    if (opened.has(i) || revealing.has(i)) return Promise.resolve();
    revealing.add(i);
    const f = SPOT_RECTS[i].face, cx = f.x + f.w / 2, cy = f.y + f.h / 2, R = Math.hypot(f.w, f.h) / 2;
    return stage.run(420 + delay, (t, ms) => {
      const k = clamp01((ms / (stage.speed || 1) - delay) / 420);
      if (k <= 0) return;
      coat.save();
      coat.globalCompositeOperation = "destination-out";
      coat.beginPath();
      coat.arc(cx, cy, R * easeOutCubic(k), 0, TAU);
      coat.fill();
      coat.restore();
      coatTex.needsUpdate = true;
      if (k > 0.05 && k < 0.6 && Math.random() < 0.6) {
        const local = new T.Vector3((cx + (Math.random() - 0.5) * f.w) / unit - w / 2, h / 2 - (cy + (Math.random() - 0.5) * f.h) / unit, 0.05);
        spawn(ticket.localToWorld(local), 2);
      }
      if (k >= 1 && !opened.has(i)) {
        opened.add(i);
        revealing.delete(i);
        glows[i].visible = !!data.spots[i]?.won;
      }
    }).finished;
  };
  // Pointer scratching: raycast to ticket UV, erase foil, shed flakes.
  const ray = new T.Raycaster(), ndc = new T.Vector2(), canvas = stage.renderer.domElement;
  let down = false, last = null, lastCheck = 0;
  const hitAt = (ev) => {
    const r = canvas.getBoundingClientRect();
    ndc.set(((ev.clientX - r.left) / r.width) * 2 - 1, -((ev.clientY - r.top) / r.height) * 2 + 1);
    ray.setFromCamera(ndc, camera);
    return ray.intersectObject(foil)[0];
  };
  const spotAt = (x, y) => SPOT_RECTS.findIndex(({ face: f }) => x >= f.x && x <= f.x + f.w && y >= f.y && y <= f.y + f.h);
  const check = (force) => {
    const now = performance.now();
    if (!force && now - lastCheck < 160) return;
    lastCheck = now;
    for (let i = 0; i < 10; i++) {
      if (opened.has(i) || revealing.has(i)) continue;
      if (coverage(i) > 0.42) dissolve(i).then(() => onSpot(i));
    }
  };
  const scratchTo = (ev) => {
    const hit = hitAt(ev);
    if (!hit) {
      last = null;
      return;
    }
    const x = hit.uv.x * W, y = (1 - hit.uv.y) * H;
    if (spotAt(x, y) < 0 && !last) return;
    coat.save();
    coat.globalCompositeOperation = "destination-out";
    coat.lineCap = "round";
    coat.lineWidth = 64;
    coat.beginPath();
    coat.moveTo(...(last || [x, y]));
    coat.lineTo(x, y);
    coat.stroke();
    coat.restore();
    coatTex.needsUpdate = true;
    if (spotAt(x, y) >= 0 && !opened.has(spotAt(x, y))) spawn(hit.point, 3);
    last = [x, y];
    stage.invalidate();
    check(false);
  };
  const onDown = (ev) => {
    if (!data.purchased || ev.button > 0) return;
    const hit = hitAt(ev);
    if (!hit || spotAt(hit.uv.x * W, (1 - hit.uv.y) * H) < 0) return;
    down = true;
    stage.hold = true;
    last = null;
    canvas.setPointerCapture(ev.pointerId);
    ev.preventDefault();
    scratchTo(ev);
  };
  const onMove = (ev) => down && scratchTo(ev);
  const onUp = () => {
    if (!down) return;
    down = false;
    stage.hold = false;
    last = null;
    check(true);
  };
  canvas.addEventListener("pointerdown", onDown);
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerup", onUp);
  canvas.addEventListener("pointercancel", onUp);
  stage.fit = (aspect) => {
    const half = Math.tan(((camera.fov / 2) * Math.PI) / 180);
    const dist = Math.max((h / 2 + 0.35) / half, (w / 2 + 0.3) / (half * aspect));
    stage.setView([0, 0.25, dist], [0, 0, 0]);
  };
  const disposeStage = stage.dispose.bind(stage);
  stage.dispose = () => {
    canvas.removeEventListener("pointerdown", onDown);
    canvas.removeEventListener("pointermove", onMove);
    canvas.removeEventListener("pointerup", onUp);
    canvas.removeEventListener("pointercancel", onUp);
    disposeStage();
  };
  return {
    stage,
    // data: {purchased, serial, price, unit, spots:[{won,payout,multiplier}]}, opened: indices.
    setTicket(next, { animate = false, opened: already = [] } = {}) {
      const changed = next.serial !== data.serial || next.purchased !== data.purchased;
      data = next;
      if (changed) {
        opened = new Set(already);
        revealing = new Set();
      }
      paintAll();
      if (animate && changed && !stage.reduced) {
        const mine = ++entering;
        flying = true;
        stage.run(750, (t) => {
          if (mine !== entering) return;
          const e = easeOutCubic(t);
          ticket.position.set(0, lerp(-h * 1.1, 0, e), lerp(-1.5, 0, e));
          ticket.rotation.set(lerp(-0.9, -0.1, e), 0, lerp(0.35, 0, e));
          if (t >= 1) flying = false;
        });
      }
    },
    revealAll() {
      let n = 0;
      return Promise.all(SPOT_RECTS.map((_, i) => (opened.has(i) || revealing.has(i) ? null : dissolve(i, 90 * n++))));
    },
    celebrate() {
      if (!stage.reduced) stage.burst([0, -h / 2 + 0.6, 1.4], { count: 46, spread: 4, lift: 4.4 });
    },
  };
}

const BUILDERS = { dice: diceScene, coin: coinScene, roulette: rouletteScene, slots: slotsScene, blackjack: blackjackScene, scratch: scratchScene };
export const SCENE_GAMES = new Set(Object.keys(BUILDERS));

// Closer, slightly angled framing for the lobby covers.
const COVER_VIEWS = {
  slots: [[1.7, 0.8, 7.6], [0, -0.05, 0]],
  roulette: [[0, 7.9, 5.3], [0, 0, 0.3]],
  coin: [[0, 3.5, 2.5], [0, 0, 0.05]],
  dice: [[1.1, 4.3, 3.7], [0, 0.2, 0.1]],
  blackjack: [[0, 4.4, 3.6], [0, 0, 0.1]],
  scratch: [[3.6, 2.2, 9.6], [0, 0.55, 0]],
};

export function buildScene(T, game, host, options = {}) {
  const ctl = BUILDERS[game](T, host, options);
  const stage = ctl.stage;
  if (options.cover && COVER_VIEWS[game]) {
    stage.fit = () => stage.setView(...COVER_VIEWS[game]);
    stage.parallax = 0.5;
  }
  stage.coinPool();
  ctl.show?.(null);
  // Compile every shader before the scene is shown, off the main thread where supported,
  // so the first spin does not stall while programs link.
  // A hidden warm-up frame then uploads textures and builds shadow programs.
  const ready = stage.renderer.compileAsync(stage.scene, stage.camera).catch(() => {}).then(() => {
    if (!stage.disposed) stage.renderer.render(stage.scene, stage.camera);
  });
  // One still frame (lobby covers): framing settled, drift at rest.
  const snapshot = () => {
    stage.resize();
    stage.pointer.x = stage.pointer.y = 0;
    stage.clock = 0;
    stage.applyCamera(0);
    stage.renderer.render(stage.scene, stage.camera);
    return stage.renderer.domElement.toDataURL("image/png");
  };
  if (!ctl.play) return { ...ctl, ready, snapshot, resize: () => stage.resize(), dispose: () => stage.dispose() };
  const keyOf = (round) => (round ? `${round.id}:${round.version ?? ""}` : null);
  let lastShown;
  return {
    show(round) {
      const key = keyOf(round);
      if (round && lastShown === key) return;
      lastShown = key;
      ctl.show(round);
    },
    // With reduced motion the same story plays, faster and without camera drift or coin bursts.
    play(round, { reduced = false } = {}) {
      lastShown = keyOf(round);
      stage.reduced = reduced;
      stage.speed = reduced ? 0.55 : 1;
      stage.busy = true;
      host.dataset.motion = "running";
      const run = ctl.play(round);
      const finish = () => {
        stage.busy = false;
        stage.speed = 1;
        delete host.dataset.motion;
      };
      run.finished.then(() => {
        finish();
        ctl.show(round);
        if (Number(round.net) > 0 && round.status !== "playing" && !reduced) stage.burst(ctl.burstAt);
        stage.invalidate();
      });
      return { finished: run.finished, cancel: () => {
        run.cancel();
        finish();
        ctl.show(round);
      } };
    },
    ready,
    snapshot,
    // Freeze the play animation of `round` at progress t (0..1), e.g. a coin mid-air.
    pose(round, t) {
      const run = ctl.play(round), task = [...stage.tasks].pop();
      task?.update(t, t * task.duration);
      run.cancel();
      lastShown = null;
      stage.invalidate();
    },
    resize: () => stage.resize(),
    dispose: () => stage.dispose(),
  };
}
