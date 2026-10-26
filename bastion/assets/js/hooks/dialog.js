// Модальные окна на <dialog>: открыть — JS.dispatch("bastion:open-dialog", to: "#id"),
// закрыть с сервера — push_event("close-dialog", %{id: "..."})
window.addEventListener("bastion:open-dialog", (e) => e.target.showModal())
window.addEventListener("bastion:close-dialog", (e) => e.target.close())
window.addEventListener("phx:close-dialog", (e) => document.getElementById(e.detail.id)?.close())
