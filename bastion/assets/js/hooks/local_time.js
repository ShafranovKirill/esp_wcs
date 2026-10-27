const lang = () => document.documentElement.lang || navigator.language

const UNITS = [
  ["year", 365 * 24 * 3600],
  ["month", 30 * 24 * 3600],
  ["day", 24 * 3600],
  ["hour", 3600],
  ["minute", 60],
  ["second", 1],
]

function relative(date) {
  const diff = (date.getTime() - Date.now()) / 1000
  const fmt = new Intl.RelativeTimeFormat(lang(), {numeric: "auto"})
  for (const [unit, seconds] of UNITS) {
    if (Math.abs(diff) >= seconds || unit === "second") {
      return fmt.format(Math.round(diff / seconds), unit)
    }
  }
}

function render(el) {
  const date = new Date(el.getAttribute("datetime"))
  if (isNaN(date)) return
  el.title = date.toLocaleString(lang())
  el.textContent =
    el.dataset.format === "relative"
      ? relative(date)
      : date.toLocaleString(lang(), {dateStyle: "medium", timeStyle: "short"})
}

export const LocalTime = {
  mounted() {
    render(this.el)
    if (this.el.dataset.format === "relative") {
      this.timer = setInterval(() => render(this.el), 30_000)
    }
  },
  updated() {
    render(this.el)
  },
  destroyed() {
    clearInterval(this.timer)
  },
}
