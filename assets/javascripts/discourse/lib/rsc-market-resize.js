// Local layout preference only. Dragging never changes or submits an order.
const KEY = "rsc-market-split-v1";
const DEFAULT = 1.15 / 2.15;
export default function attachMarketResize(handle) {
  const pane = handle.parentElement;
  const desktop = window.matchMedia("(min-width: 1100px)");
  let ratio = DEFAULT, drag = null;
  try { const saved = Number(localStorage.getItem(KEY)); if (saved > 0 && saved < 1) ratio = saved; } catch {}
  const limits = () => {
    const width = Math.max(1, pane.clientWidth - 20);
    const min = Math.min(280, width / 2), max = Math.max(min, width - 330);
    return { width, min, max };
  };
  const paint = () => {
    if (!desktop.matches) { pane.style.removeProperty("--rsc-market-left"); return; }
    const { width, min, max } = limits();
    const left = Math.max(min, Math.min(max, ratio * width));
    pane.style.setProperty("--rsc-market-left", `${left}px`);
    handle.setAttribute("aria-valuemin", Math.round(min / width * 100));
    handle.setAttribute("aria-valuemax", Math.round(max / width * 100));
    handle.setAttribute("aria-valuenow", Math.round(left / width * 100));
    handle.setAttribute("aria-valuetext", `行情列表 ${Math.round(left / width * 100)}%，右侧详情 ${100 - Math.round(left / width * 100)}%`);
  };
  const save = () => { try { localStorage.setItem(KEY, String(ratio)); } catch {} };
  const adjust = (left) => { const { width, min, max } = limits(); ratio = Math.max(min, Math.min(max, left)) / width; paint(); };
  const finish = (event, cancel = false) => {
    if (!drag || (event && event.pointerId !== drag.id)) return;
    const old = drag; drag = null;
    if (cancel) ratio = old.ratio; else save();
    document.documentElement.classList.remove("rsc-market-resizing");
    if (handle.hasPointerCapture(old.id)) handle.releasePointerCapture(old.id);
    paint();
  };
  const down = event => {
    if (!desktop.matches || event.button !== 0 || drag) return;
    event.preventDefault(); handle.focus({ preventScroll: true });
    drag = { id:event.pointerId, ratio }; handle.setPointerCapture(event.pointerId);
    document.documentElement.classList.add("rsc-market-resizing");
  };
  const move = event => { if (drag && event.pointerId === drag.id) adjust(event.clientX - pane.getBoundingClientRect().left - 10); };
  const up = event => finish(event);
  const cancel = event => finish(event, true);
  const reset = () => { ratio = DEFAULT; paint(); save(); };
  const key = event => {
    if (!desktop.matches) return;
    const { width, min, max } = limits();
    const left = parseFloat(pane.style.getPropertyValue("--rsc-market-left"));
    if (event.key === "ArrowLeft") adjust(left - width * .02);
    else if (event.key === "ArrowRight") adjust(left + width * .02);
    else if (event.key === "Home") adjust(min);
    else if (event.key === "End") adjust(max);
    else if (event.key === "Enter") reset();
    else if (event.key === "Escape" && drag) finish(null, true);
    else return;
    event.preventDefault(); if (!drag) save();
  };
  const resize = () => { if (!desktop.matches && drag) finish(null, true); paint(); };
  const observer = new ResizeObserver(resize); observer.observe(pane);
  const handlers = { pointerdown:down, pointermove:move, pointerup:up, pointercancel:cancel, lostpointercapture:cancel, dblclick:reset, keydown:key };
  for (const [type, callback] of Object.entries(handlers)) handle.addEventListener(type, callback);
  desktop.addEventListener("change", resize); paint();
  return () => {
    finish(null, true); observer.disconnect(); desktop.removeEventListener("change", resize);
    for (const [type, callback] of Object.entries(handlers)) handle.removeEventListener(type, callback);
    pane.style.removeProperty("--rsc-market-left");
  };
}
