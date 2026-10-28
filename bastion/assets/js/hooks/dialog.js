window.addEventListener("bastion:open-dialog", (e) => e.target.showModal())
window.addEventListener("bastion:close-dialog", (e) => e.target.close())
window.addEventListener("phx:close-dialog", (e) => document.getElementById(e.detail.id)?.close())
window.addEventListener("phx:open-dialog", (e) => document.getElementById(e.detail.id)?.showModal())
