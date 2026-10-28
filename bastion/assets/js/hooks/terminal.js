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
    this.owner = false
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

    this.banner = JSON.parse(this.el.dataset.banner || "[]")
    this.writeBanner()

    this.term.onData(data => {
      if (this.owner) this.pushEvent("console-input", {data})
    })

    this.handleEvent("console-reset", ({data}) => {
      this.term.reset()
      this.writeBanner()
      if (data) this.term.write(decode(data))
    })
    this.handleEvent("console-output", ({data}) => this.term.write(decode(data)))
    this.handleEvent("console-state", ({owner}) => {
      this.owner = owner
      this.term.options.disableStdin = !owner
      this.term.options.cursorBlink = owner
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
  writeBanner() {
    for (const line of this.banner) this.term.writeln(line)
  },
  destroyed() {
    clearInterval(this.ping)
    this.resizeObserver.disconnect()
    this.themeObserver.disconnect()
    this.term.dispose()
  },
}
