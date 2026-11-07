import {DETECTION_BAUDS, assessSample} from "./baud_detection"
import {Terminal as XTerm} from "../../vendor/xterm/xterm.mjs"
import {FitAddon} from "../../vendor/xterm/addon-fit.mjs"

const THEMES = {
  dark: {background: "#0b0f14", foreground: "#d6deeb", cursor: "#82aaff"},
  light: {background: "#fafafa", foreground: "#1f2328", cursor: "#0969da"},
}

const PING_MS = 60_000

const currentTheme = () =>
  document.documentElement.getAttribute("data-theme") === "dark" ? THEMES.dark : THEMES.light

const decode = b64 => Uint8Array.from(atob(b64), c => c.charCodeAt(0))

export const Terminal = {
  mounted() {
    this.recording = false
    this.recorded = []
    this.recordedBytes = 0
    this.recordToggle = document.getElementById("terminal-record")
    this.recordExport = document.getElementById("terminal-record-export")
    this.recordStatus = document.getElementById("terminal-record-status")
    this.recordListener = () => {
      if (this.recording) this.stopRecording()
      else {
        this.recorded = []
        this.recordedBytes = 0
        this.recordingStarted = new Date().toISOString()
        this.recording = true
        this.recordToggle.textContent = this.recordToggle.dataset.stop
        this.recordStatus.textContent = this.recordStatus.dataset.recording
        this.recordExport.disabled = true
      }
    }
    this.recordExportListener = () => {
      const file = {version: 1, device: this.el.dataset.deviceId, started_at: this.recordingStarted, events: this.recorded}
      this.downloadFile(JSON.stringify(file, null, 2), "application/json", `session-${this.el.dataset.deviceId}-${Date.now()}.json`)
      this.recordToggle.disabled = false
    }
    this.recordToggle.addEventListener("click", this.recordListener)
    this.recordExport.addEventListener("click", this.recordExportListener)
    this.sequenceRunning = false
    this.owner = false
    this.scan = null
    this.labels = JSON.parse(this.el.dataset.toolsLabels || "{}")
    this.preferenceKey = `wcs-terminal:${this.el.dataset.deviceId}`
    this.preference = {backspace: "del", label: ""}
    try {
      const saved = JSON.parse(localStorage.getItem(this.preferenceKey) || "null")
      if (saved && ["bs", "del"].includes(saved.backspace)) this.preference = saved
    } catch {}
    this.backspaceSelect = document.getElementById("console-backspace")
    this.profileName = document.getElementById("console-profile-name")
    this.backspaceSelect.value = this.preference.backspace
    this.profileName.textContent = this.preference.label || ""
    this.keyboardChange = () => {
      this.preference.backspace = this.backspaceSelect.value
      this.savePreference()
    }
    this.backspaceSelect.addEventListener("change", this.keyboardChange)
    this.fullscreenListener = async () => {
      if (document.fullscreenElement) await document.exitFullscreen()
      else await this.el.closest("#console").requestFullscreen?.()
    }
    this.downloadListener = () => {
      const buffer = this.term.buffer.active
      const lines = Array.from({length: buffer.length}, (_, i) => buffer.getLine(i)?.translateToString(true) || "")
      const url = URL.createObjectURL(new Blob([lines.join("\n")], {type: "text/plain;charset=utf-8"}))
      const link = document.createElement("a")
      link.href = url
      link.download = `console-${this.el.dataset.deviceId}.txt`
      link.click()
      setTimeout(() => URL.revokeObjectURL(url), 1000)
    }
    this.el.addEventListener("wcs:terminal-fullscreen", this.fullscreenListener)
    this.el.addEventListener("wcs:terminal-download", this.downloadListener)
    this.autoBaudListener = () => this.detectBaud()
    this.el.addEventListener("wcs:autobaud", this.autoBaudListener)
    this.term = new XTerm({
      cursorBlink: true,
      fontFamily: 'ui-monospace, "JetBrains Mono", Menlo, Consolas, monospace',
      fontSize: 14,
      scrollback: 5000,
      theme: currentTheme(),
      disableStdin: true,
    })
    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.el)
    this.fit.fit()


    this.term.attachCustomKeyEventHandler(event => {
      if (event.key !== "Backspace" || event.ctrlKey || event.altKey || event.metaKey) return true
      if (event.type === "keydown" && this.owner && !this.scan && !this.sequenceRunning) {
        this.sendInput(this.preference.backspace === "bs" ? "\x08" : "\x7f")
      }
      return false
    })

    this.term.onData(data => {
      if (this.owner && !this.scan && !this.sequenceRunning) this.sendInput(data)
    })

    this.handleEvent("console-reset", ({data}) => {
      this.term.reset()
      if (data) { this.record("history", data); this.term.write(decode(data)) }
    })
    this.handleEvent("console-output", ({data}) => {
      this.record("output", data)
      const bytes = decode(data)
      if (this.scan?.collecting && this.scan.bytes.length < 4096) this.scan.bytes.push(...bytes.subarray(0, 4096 - this.scan.bytes.length))
      this.term.write(bytes)
    })
    this.handleEvent("terminal-profile", profile => {
      this.preference = {backspace: profile.backspace, label: profile.label}
      this.backspaceSelect.value = profile.backspace
      this.profileName.textContent = profile.label
      this.savePreference()
      this.term.focus()
    })
    this.handleEvent("sequence-state", ({running}) => {
      this.sequenceRunning = running
      this.term.options.disableStdin = !this.owner || running
      this.term.options.cursorBlink = this.owner && !running
    })
    this.handleEvent("sequence-input", ({data}) => this.record("sequence_input", data))
    this.handleEvent("console-state", ({owner}) => {
      this.owner = owner
      if (!owner && this.scan) this.scan.cancelled = true
      this.term.options.disableStdin = !owner || this.sequenceRunning
      this.term.options.cursorBlink = owner && !this.sequenceRunning
      if (owner) this.term.focus()
    })

    this.ping = setInterval(() => {
      if (this.owner) this.pushEvent("console-ping", {})
    }, PING_MS)

    this.resizeObserver = new ResizeObserver(() => this.fit.fit())
    this.resizeObserver.observe(this.el)

    this.themeObserver = new MutationObserver(() => (this.term.options.theme = currentTheme()))
    this.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  },
  sendInput(data) {
    const bytes = new TextEncoder().encode(data)
    this.record("browser_input", btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join("")))
    this.pushEvent("console-input", {data})
  },
  record(direction, data) {
    if (!this.recording) return
    const event = {at: new Date().toISOString(), direction, text: new TextDecoder().decode(decode(data)), data_base64: data}
    const size = new TextEncoder().encode(JSON.stringify(event)).length
    if (this.recordedBytes + size > 2 * 1024 * 1024) {
      this.stopRecording()
      this.recordStatus.textContent = this.recordStatus.dataset.limit
      return
    }
    this.recorded.push(event)
    this.recordedBytes += size
    this.recordExport.disabled = false
  },
  stopRecording() {
    this.recording = false
    this.recordToggle.textContent = this.recordToggle.dataset.start
    this.recordToggle.disabled = this.recorded.length > 0
    this.recordStatus.textContent = this.recordStatus.dataset.stopped
  },
  downloadFile(data, type, filename) {
    const url = URL.createObjectURL(new Blob([data], {type}))
    const link = document.createElement("a")
    link.href = url
    link.download = filename
    link.click()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
  },
  savePreference() {
    try {localStorage.setItem(this.preferenceKey, JSON.stringify(this.preference))} catch {}
  },
  request(event, params) {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(this.labels.failed)), 15000)
      this.pushEvent(event, params, reply => {
        clearTimeout(timeout)
        if (reply.ok) resolve(reply)
        else reject(new Error(reply.error || this.labels.failed))
      })
    })
  },
  async detectBaud() {
    if (!this.owner || this.scan) return
    const panel = document.getElementById("console-detection")
    const status = document.createElement("p")
    const note = document.createElement("p")
    const cancel = document.createElement("button")
    note.textContent = this.labels.passive
    note.className = "text-sm text-base-content/60"
    cancel.textContent = this.labels.cancel
    cancel.className = "btn btn-sm"
    const scan = {cancelled: false, collecting: false, bytes: []}
    this.scan = scan
    this.term.options.disableStdin = true
    cancel.onclick = () => {scan.cancelled = true}
    panel.replaceChildren(status, note, cancel)
    let candidate = null
    let failure = null
    let restored = true
    let probed = false
    try {
      for (const baud of DETECTION_BAUDS) {
        if (scan.cancelled || !this.owner) break
        status.textContent = `${this.labels.listening} ${baud} · 8N1`
        await this.request("console-probe", {line: {baud, data_bits: 8, parity: "none", stop_bits: 1}})
        probed = true
        await new Promise(resolve => setTimeout(resolve, 200))
        scan.bytes = []
        scan.collecting = true
        await new Promise(resolve => setTimeout(resolve, 1600))
        scan.collecting = false
        const assessment = assessSample(scan.bytes)
        if (assessment) {
          candidate = {baud, ...assessment}
          break
        }
      }
    } catch (error) {
      failure = error.message
    } finally {
      scan.collecting = false
      if (probed && !this.owner) restored = false
      if (probed && this.owner && !this.destroyedFlag) {
        try {await this.request("console-probe-end", {})} catch {restored = false}
      }
      this.scan = null
      this.term.options.disableStdin = !this.owner
    }
    if (this.destroyedFlag) return
    cancel.remove()
    if (!restored) {
      status.textContent = this.labels.restore_failed
    } else if (scan.cancelled || !this.owner) {
      status.textContent = this.labels.cancelled
    } else if (failure) {
      status.textContent = failure
    } else if (candidate) {
      status.textContent = `${candidate.baud} · ${this.labels.probable}`
      const preview = document.createElement("pre")
      preview.className = "overflow-auto rounded-box bg-base-200 p-3 text-xs"
      preview.textContent = candidate.sample
      const apply = document.createElement("button")
      apply.className = "btn btn-primary btn-sm"
      apply.textContent = `${this.labels.apply}: ${candidate.baud}`
      apply.onclick = () => {
        if (!this.owner || this.scan) return
        this.pushEvent("console-line", {line: {baud: candidate.baud, data_bits: 8, parity: "none", stop_bits: 1}})
        apply.disabled = true
      }
      panel.append(preview, apply)
    } else {
      status.textContent = this.labels.no_data
    }
  },
  destroyed() {
    this.destroyedFlag = true
    this.recordToggle.removeEventListener("click", this.recordListener)
    this.recordExport.removeEventListener("click", this.recordExportListener)
    this.recorded = []
    if (this.scan) this.scan.cancelled = true
    this.backspaceSelect.removeEventListener("change", this.keyboardChange)
    this.el.removeEventListener("wcs:autobaud", this.autoBaudListener)
    this.el.removeEventListener("wcs:terminal-fullscreen", this.fullscreenListener)
    this.el.removeEventListener("wcs:terminal-download", this.downloadListener)
    clearInterval(this.ping)
    this.resizeObserver.disconnect()
    this.themeObserver.disconnect()
    this.term.dispose()
  },
}
