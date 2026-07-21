document.addEventListener("click", (event) => {
  const opener = event.target.closest("[data-dialog]");
  if (opener) document.getElementById(opener.dataset.dialog)?.showModal();
  if (event.target.closest("[data-close]")) event.target.closest("dialog")?.close();
});

