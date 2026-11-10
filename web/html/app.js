// Front end: talks only to /api/* on the same origin. Nginx forwards those
// calls to the application tier, so the browser never sees the app servers.
const list = document.getElementById("task-list");
const empty = document.getElementById("empty");
const errorBox = document.getElementById("error");

function showError(msg) {
  errorBox.textContent = msg;
  errorBox.hidden = !msg;
}

async function api(path, options = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  if (!res.ok && res.status !== 204) {
    const body = await res.json().catch(() => ({}));
    throw new Error(body.error || `Request failed (${res.status})`);
  }
  return res.status === 204 ? null : res.json();
}

function render(tasks) {
  list.innerHTML = "";
  empty.hidden = tasks.length > 0;
  for (const t of tasks) {
    const li = document.createElement("li");
    li.className = t.done ? "done" : "";

    const box = document.createElement("input");
    box.type = "checkbox";
    box.checked = t.done;
    box.addEventListener("change", () =>
      api(`/api/tasks/${t.id}`, { method: "PATCH", body: JSON.stringify({ done: box.checked }) })
        .then(load).catch((e) => showError(e.message)));

    const span = document.createElement("span");
    span.textContent = t.title; // textContent, never innerHTML: avoids XSS

    const del = document.createElement("button");
    del.className = "link";
    del.textContent = "Delete";
    del.addEventListener("click", () =>
      api(`/api/tasks/${t.id}`, { method: "DELETE" }).then(load).catch((e) => showError(e.message)));

    li.append(box, span, del);
    list.append(li);
  }
}

async function load() {
  try {
    const data = await api("/api/tasks");
    render(data.tasks);
    document.getElementById("app-id").textContent = data.served_by.instance_id;
    document.getElementById("app-az").textContent = data.served_by.availability_zone;
    document.getElementById("app-ver").textContent = data.served_by.version.slice(0, 7);
    showError("");
  } catch (e) {
    showError(e.message);
  }
  fetch("/web-info").then((r) => r.json()).then((w) => {
    document.getElementById("web-id").textContent = w.instance_id;
    document.getElementById("web-az").textContent = w.availability_zone;
  }).catch(() => {});
  fetch("/api/health/db").then((r) => r.json()).then((d) => {
    document.getElementById("db-status").textContent = d.status === "ok" ? "Connected (RDS MySQL)" : "Unreachable";
  }).catch(() => {});
}

document.getElementById("task-form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const input = document.getElementById("task-title");
  try {
    await api("/api/tasks", { method: "POST", body: JSON.stringify({ title: input.value }) });
    input.value = "";
    load();
  } catch (e) {
    showError(e.message);
  }
});

load();
