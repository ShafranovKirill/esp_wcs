export const FolderMap = {
  mounted() {
    this.abort = new AbortController()
    this.scale = 1; this.dx = 0; this.dy = 0; this.pointers = new Map()
    this.stage = document.createElement("div")
    Object.assign(this.stage.style, {position: "absolute", transformOrigin: "0 0"})
    this.el.append(this.stage)
    const on = (el, name, fn, opts = {}) => el.addEventListener(name, fn, {...opts, signal: this.abort.signal})
    this.page = this.el.closest("#folder-map-page")
    this.handleEvent("map-focus", ({id}) => {
      const item = JSON.parse(this.el.dataset.items).find(item => item.id === id)
      if (!item) return
      this.dx = this.el.clientWidth / 2 - item.x * this.width * this.scale
      this.dy = this.el.clientHeight / 2 - item.y * this.height * this.scale
      this.transform()
      const marker = [...this.stage.querySelectorAll("[data-marker]")].find(marker => JSON.parse(marker.dataset.marker).id === id)
      marker?.focus({preventScroll: true})
    })
    on(window, "keydown", e => {
      if (e.key !== "Escape" || e.repeat || e.target.closest("input, select, textarea, dialog")) return
      if (this.selected) {
        this.selected = null
        this.el.style.cursor = ""
        this.page.querySelectorAll("[aria-pressed=true]").forEach(el => el.setAttribute("aria-pressed", "false"))
        e.preventDefault()
      }
    })
    on(this.page, "dragstart", e => {
      const item = e.target.closest("[data-map-id]")
      if (item && this.editing) e.dataTransfer.setData("application/x-wcs-map", JSON.stringify({id: item.dataset.mapId, kind: item.dataset.mapKind}))
    })
    on(this.page, "click", e => {
      const control = e.target.closest("[data-map-control]")
      if (control) {
        if (control.dataset.mapControl === "fullscreen") {
          const workspace = this.page.querySelector("#map-workspace")
          if (document.fullscreenElement) document.exitFullscreen()
          else workspace.requestFullscreen?.()
        } else if (control.dataset.mapControl === "fit") this.fit()
        else this.zoom(control.dataset.mapControl === "in" ? 1.25 : 0.8, this.el.clientWidth / 2, this.el.clientHeight / 2)
      }
      const item = e.target.closest("[data-map-id]")
      if (item && this.editing) {
        this.selected = {id: item.dataset.mapId, kind: item.dataset.mapKind}
        this.page.querySelectorAll("[data-map-id]").forEach(b => b.setAttribute("aria-pressed", String(b === item)))
        this.el.style.cursor = "crosshair"
      }
    })
    on(this.el, "dragover", e => { if (this.editing) e.preventDefault() })
    on(this.el, "drop", e => {
      if (!this.editing) return
      e.preventDefault()
      try { this.place(JSON.parse(e.dataTransfer.getData("application/x-wcs-map")), e.clientX, e.clientY) } catch (_) { /* unrelated drag */ }
    })
    on(this.el, "wheel", e => {
      e.preventDefault()
      const r = this.el.getBoundingClientRect()
      this.zoom(Math.exp(-e.deltaY * 0.001), e.clientX - r.left, e.clientY - r.top)
    }, {passive: false})
    on(this.el, "pointerdown", e => {
      if (e.button !== 0) return
      this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
      if (this.pointers.size === 2) { this.gesture = null; this.pinch = this.pinchState(); return }
      const marker = e.target.closest("[data-marker]")
      if (this.selected && !marker) {
        this.place(this.selected, e.clientX, e.clientY); this.selected = null; this.el.style.cursor = ""; return
      }
      this.gesture = {id: e.pointerId, x: e.clientX, y: e.clientY, dx: this.dx, dy: this.dy, marker,
        item: marker && JSON.parse(marker.dataset.marker), moved: false}
      if (this.editing || !marker) this.el.setPointerCapture(e.pointerId)
    })
    on(this.el, "pointermove", e => {
      if (!this.pointers.has(e.pointerId)) return
      this.pointers.set(e.pointerId, {x: e.clientX, y: e.clientY})
      if (this.pointers.size === 2) {
        const next = this.pinchState(), old = this.pinch
        if (old) {
          const r = this.el.getBoundingClientRect()
          this.zoom(next.distance / old.distance, old.x - r.left, old.y - r.top)
          this.dx += next.x - old.x; this.dy += next.y - old.y; this.transform()
        }
        this.pinch = next; return
      }
      const g = this.gesture
      if (!g || g.id !== e.pointerId) return
      const x = e.clientX - g.x, y = e.clientY - g.y
      if (Math.hypot(x, y) < 5 && !g.moved) return
      g.moved = true
      if (g.marker && this.editing) {
        const p = this.position(e.clientX, e.clientY)
        g.marker.style.left = `${p.x * 100}%`; g.marker.style.top = `${p.y * 100}%`
      } else { this.dx = g.dx + x; this.dy = g.dy + y; this.transform() }
    })
    const end = e => {
      const g = this.gesture
      this.pointers.delete(e.pointerId); this.pinch = null
      if (g && g.id === e.pointerId) {
        if (g.moved) {
          this.suppressClick = true
          if (g.marker && this.editing && e.type !== "pointercancel") this.place(g.item, e.clientX, e.clientY)
        }
        this.gesture = null
      }
    }
    on(this.el, "pointerup", end); on(this.el, "pointercancel", end)
    on(this.el, "click", e => {
      if (this.suppressClick || this.editing) { e.preventDefault(); this.suppressClick = false }
    })
    this.el.tabIndex = 0
    on(this.el, "keydown", e => {
      if (e.key === "0") this.fit()
      if (["+", "="].includes(e.key)) this.zoom(1.25, this.el.clientWidth / 2, this.el.clientHeight / 2)
      if (e.key === "-") this.zoom(0.8, this.el.clientWidth / 2, this.el.clientHeight / 2)
      const delta = {ArrowLeft:[40,0], ArrowRight:[-40,0], ArrowUp:[0,40], ArrowDown:[0,-40]}[e.key]
      if (delta) { e.preventDefault(); this.dx += delta[0]; this.dy += delta[1]; this.transform() }
    })
    on(this.el, "dblclick", e => {
      if (e.target.closest("[data-marker]")) return
      const r = this.el.getBoundingClientRect()
      this.zoom(1.5, e.clientX - r.left, e.clientY - r.top)
    })
    this.resize = new ResizeObserver(() => { if (!this.hasFitted) this.fit() }); this.resize.observe(this.el)
    this.sync()
  },
  updated() { this.sync() },
  destroyed() { this.abort.abort(); this.resize.disconnect() },
  pinchState() {
    const [a, b] = [...this.pointers.values()]
    return {x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, distance: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y))}
  },
  position(x, y) {
    const r = this.el.getBoundingClientRect()
    return {x: Math.max(0, Math.min(1, (x - r.left - this.dx) / (this.width * this.scale))),
      y: Math.max(0, Math.min(1, (y - r.top - this.dy) / (this.height * this.scale)))}
  },
  place(item, x, y) { if (this.editing && item) this.pushEvent("place", {...item, ...this.position(x, y)}) },
  transform() {
    this.stage.style.transform = `translate(${this.dx}px, ${this.dy}px) scale(${this.scale})`
    this.stage.querySelectorAll("[data-marker]").forEach(marker => {
      marker.classList.toggle("map-marker-compact", this.scale < 0.35)
      marker.style.transform = `translate(-50%, -50%) scale(${1 / this.scale})`
    })
  },
  fit() {
    if (!this.width || !this.height) return
    this.scale = Math.max(0.02, Math.min((this.el.clientWidth - 48) / this.width, (this.el.clientHeight - 48) / this.height))
    this.dx = (this.el.clientWidth - this.width * this.scale) / 2
    this.dy = (this.el.clientHeight - this.height * this.scale) / 2
    this.hasFitted = this.el.clientWidth > 0 && this.el.clientHeight > 0
    this.transform()
  },
  zoom(factor, x, y) {
    const scale = Math.max(0.02, Math.min(8, this.scale * factor)), ratio = scale / this.scale
    this.dx = x - (x - this.dx) * ratio; this.dy = y - (y - this.dy) * ratio
    this.scale = scale; this.transform()
  },
  sync() {
    const d = this.el.dataset
    const refit = this.width !== Number(d.width) || this.height !== Number(d.height) || this.background !== d.background
    this.width = Number(d.width); this.height = Number(d.height); this.background = d.background; this.editing = d.editing === "true"
    if (!this.editing) { this.selected = null; this.el.style.cursor = "" }
    Object.assign(this.stage.style, {width: `${this.width}px`, height: `${this.height}px`, background: "var(--color-base-100, #fff)"})
    this.stage.replaceChildren()
    if (this.background) {
      const img = document.createElement("img"); img.src = this.background; img.alt = ""; img.draggable = false
      Object.assign(img.style, {width: "100%", height: "100%", pointerEvents: "none"}); this.stage.append(img)
    }
    const colors = {online: "#16a34a", offline: "#64748b", busy: "#d97706", empty: "#64748b"}
    JSON.parse(d.items).forEach(item => {
      const marker = document.createElement("a")
      marker.href = item.url; marker.draggable = false; marker.dataset.marker = JSON.stringify({kind: item.kind, id: item.id})
      marker.className = "map-marker"
      marker.setAttribute("aria-label", `${item.name} · ${d[item.status] || item.status}`)
      marker.title = `${item.name} · ${d[item.status] || item.status}`
      Object.assign(marker.style, {position: "absolute", left: `${item.x * 100}%`, top: `${item.y * 100}%`, transform: "translate(-50%, -50%)",
        display: "flex", alignItems: "center", gap: "6px", padding: "8px 10px", borderRadius: "9px", border: `1px solid ${colors[item.status]}`,
        background: "var(--color-base-100, white)", color: "var(--color-base-content, #111)", whiteSpace: "nowrap", fontSize: "14px", boxShadow: "0 4px 18px #0003", cursor: this.editing ? "grab" : "pointer"})
      const icon = document.createElement("span"); icon.textContent = item.kind === "folder" ? "▣" : "●"; icon.style.color = colors[item.status]
      const label = document.createElement("span"); label.textContent = item.name; label.className = "marker-label"
      marker.append(icon, label); this.stage.append(marker)
    })
    if (refit) this.fit()
    else this.transform()
  },
}
