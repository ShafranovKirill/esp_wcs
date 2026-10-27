export const Clipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const text = this.el.dataset.copy
      try {
        await navigator.clipboard.writeText(text)
      } catch (_e) {
        const area = document.createElement("textarea")
        area.value = text
        document.body.appendChild(area)
        area.select()
        document.execCommand("copy")
        area.remove()
      }
      const label = this.el.querySelector("[data-copy-label]")
      if (label) {
        const original = label.textContent
        label.textContent = this.el.dataset.copiedText || "✓"
        setTimeout(() => (label.textContent = original), 1500)
      }
    })
  },
}
