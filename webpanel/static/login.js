// Formulario de entrada del panel. Sin scripts en linea: la CSP lo exige.
(function () {
  const form = document.getElementById("login-form");
  if (!form) return;
  const error = document.getElementById("login-error");
  const clave = document.getElementById("login-clave");
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    error.textContent = "";
    let r;
    try {
      r = await fetch("/login", {
        method: "POST",
        headers: {"Content-Type": "application/json"},
        body: JSON.stringify({
          usuario: document.getElementById("login-usuario").value,
          password: clave.value,
        }),
      });
    } catch (e) {
      error.textContent = "No se pudo conectar con el panel.";
      return;
    }
    clave.value = "";
    const datos = await r.json().catch(() => ({}));
    if (r.ok) {
      location.href = "/";
    } else {
      error.textContent = datos.error || "No se pudo entrar.";
    }
  });
})();
