export const Disclosure = {
  mounted() {
    this.abort = new AbortController()
    const signal = this.abort.signal
    const summary = this.el.querySelector("summary")
    const sync = () => summary.setAttribute("aria-expanded", String(this.el.open))
    sync()
    this.el.addEventListener("toggle", () => {
      sync()
      if (this.el.open) document.querySelectorAll("details.app-disclosure[open]").forEach(el => {
        if (el !== this.el) el.open = false
      })
    }, {signal})
    document.addEventListener("click", e => {
      if (!this.el.contains(e.target)) this.el.open = false
      else if (e.target.closest("a")) this.el.open = false
    }, {signal})
    this.el.addEventListener("keydown", e => {
      if (e.key === "Escape" && this.el.open) {
        e.stopPropagation()
        this.el.open = false
        summary.focus()
      }
    }, {signal})
  },
  destroyed() { this.abort.abort() },
}

export const ThemeChoices = {
  mounted() {
    this.syncTheme = () => {
      const root = document.documentElement
      const selected = root.dataset.themeSource === "system" ? "system" : root.dataset.theme
      this.el.querySelectorAll("[data-phx-theme]").forEach(button => {
        button.setAttribute("aria-pressed", String(button.dataset.phxTheme === selected))
      })
    }
    this.syncTheme()
    this.observer = new MutationObserver(this.syncTheme)
    this.observer.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme", "data-theme-source"]})
  },
  destroyed() { this.observer.disconnect() },
}
