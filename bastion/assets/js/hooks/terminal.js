import {Terminal as XTerm} from "../../vendor/xterm/xterm.mjs"
import {FitAddon} from "../../vendor/xterm/addon-fit.mjs"

const THEMES = {
  dark: {background: "#0b0f14", foreground: "#d6deeb", cursor: "#82aaff"},
  light: {background: "#fafafa", foreground: "#1f2328", cursor: "#0969da"},
}

const currentTheme = () =>
  document.documentElement.getAttribute("data-theme") === "dark" ? THEMES.dark : THEMES.light

export const Terminal = {
  mounted() {
    this.term = new XTerm({
      cursorBlink: true,
      fontFamily: 'ui-monospace, "JetBrains Mono", Menlo, Consolas, monospace',
      fontSize: 14,
      scrollback: 5000,
      theme: currentTheme(),
      disableStdin: this.el.dataset.readonly === "true",
    })
    this.fit = new FitAddon()
    this.term.loadAddon(this.fit)
    this.term.open(this.el)
    this.fit.fit()

    for (const line of JSON.parse(this.el.dataset.banner || "[]")) {
      this.term.writeln(line)
    }

    this.onResize = () => this.fit.fit()
    window.addEventListener("resize", this.onResize)

    this.themeObserver = new MutationObserver(() => (this.term.options.theme = currentTheme()))
    this.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  },
  destroyed() {
    window.removeEventListener("resize", this.onResize)
    this.themeObserver.disconnect()
    this.term.dispose()
  },
}
