"use strict";

const state = {
  csrf: null,
  baseRevision: null,
  draft: null,
  discovery: null,
  status: null,
  yamlDirty: false,
  needsDiscoveryDefaults: false,
  activePanel: "status",
};

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const esc = (value) => String(value ?? "")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;");

async function api(path, options = {}) {
  const headers = { "Content-Type": "application/json", ...(options.headers || {}) };
  if (state.csrf && !["GET", "HEAD"].includes(options.method || "GET")) {
    headers["X-CSRF-Token"] = state.csrf;
  }
  const response = await fetch(path, { credentials: "same-origin", ...options, headers });
  if (response.status === 204) return null;
  const payload = await response.json();
  if (!response.ok) {
    const error = new Error(payload.error?.message || "Request failed");
    error.code = payload.error?.code || `HTTP_${response.status}`;
    throw error;
  }
  return payload;
}

function setGlobalMessage(message, kind = "") {
  const node = $("#global-message");
  node.textContent = message;
  node.className = `banner ${kind}`;
  node.hidden = !message;
}

function setValidation(message, kind = "") {
  const node = $("#validation-summary");
  node.textContent = message;
  node.className = `message ${kind}`;
}

function defaultDraft() {
  const listen = state.discovery?.portals?.flatMap((item) => item.listen)[0];
  return {
    schema_version: 2,
    allowed_source_cidr: "10.20.40.0/24",
    portal: { address: listen?.address || "10.20.40.10", port: listen?.port || 3260 },
    admin_api: { allowed_source_ip: "192.168.1.101", token_digest: digestPlaceholder() },
    release_management: { prefix: "games", timezone: "Asia/Yekaterinburg" },
    publisher: { source_ip: "10.20.40.100", initiator_iqn: "", target_iqn: "", volumes: {} },
    clients: {},
  };
}

function digestPlaceholder() {
  return `hmac-sha256:${"0".repeat(64)}`;
}

async function login(event) {
  event.preventDefault();
  const input = $("#login-token");
  const error = $("#login-error");
  error.hidden = true;
  try {
    const result = await api("/v1/configurator/session", {
      method: "POST",
      body: JSON.stringify({ token: input.value }),
    });
    state.csrf = result.csrf_token;
    input.value = "";
    await loadApplication();
  } catch (requestError) {
    error.textContent = requestError.message;
    error.hidden = false;
    input.value = "";
    input.focus();
  }
}

async function loadApplication() {
  try {
    const [status, document] = await Promise.all([
      api("/v1/configurator/status"),
      api("/v1/configurator/config"),
    ]);
    state.status = status;
    state.csrf = status.csrf_token;
    state.discovery = null;
    state.baseRevision = document.source_revision;
    state.draft = document.config || defaultDraft();
    state.yamlDirty = false;
    state.needsDiscoveryDefaults = !document.config && !document.yaml;
    $("#yaml-editor").value = document.yaml || yamlDump(state.draft);
    $("#login-view").hidden = true;
    $("#app-view").hidden = false;
    renderAll();
    await refreshDiscovery(false);
  } catch (error) {
    if (error.code === "UNAUTHORIZED") {
      state.csrf = null;
      $("#login-view").hidden = false;
      $("#app-view").hidden = true;
      return;
    }
    setGlobalMessage(error.message, "error");
  }
}

function renderAll() {
  renderStatus();
  renderCandidates();
  renderNetwork();
  renderPublisher();
  renderClients();
  renderDiscoveryState();
}

function renderDiscoveryState() {
  const available = state.discovery !== null;
  $("#connection-badge").textContent = available ? "TrueNAS discovery OK" : "Discovery unavailable";
  $("#connection-badge").className = available ? "badge good" : "badge error";
  setTopologyActionsEnabled(available);
}

function setTopologyActionsEnabled(enabled) {
  ["#validate-button", "#apply-yaml", "#save-button"].forEach((selector) => {
    $(selector).disabled = !enabled;
  });
}

function renderStatus() {
  const status = state.status || {};
  const saved = state.draft ? configRevisionHint() : "—";
  const targetCount = state.discovery === null ? "—" : state.discovery.targets.length;
  const datasetCount = state.discovery === null ? "—" : state.discovery.datasets.length;
  $("#status-grid").innerHTML = [
    statusCard("Startup revision", status.startup_revision || "нет"),
    statusCard("Saved revision", status.saved_revision || saved || "нет"),
    statusCard("Source revision", state.baseRevision || "новый файл"),
    statusCard("Config", status.config_valid ? "валиден" : (status.config_exists ? "ошибка" : "не создан")),
    statusCard("TrueNAS targets", targetCount),
    statusCard("Datasets", datasetCount),
  ].join("");
  const restart = status.restart_required || (
    status.startup_revision && status.saved_revision !== status.startup_revision
  );
  $("#restart-banner").hidden = !restart;
}

function statusCard(label, value) {
  return `<article class="field-card"><p class="status-label">${esc(label)}</p><p class="status-value">${esc(value)}</p></article>`;
}

function configRevisionHint() {
  return state.status?.saved_revision || "draft";
}

function renderCandidates() {
  const sessions = state.discovery?.sessions || [];
  const groups = state.discovery?.initiator_groups || [];
  const entries = groups.flatMap((group) => group.initiators || []);
  const ips = new Set(sessions.map((item) => item.initiator_addr));
  const iqns = new Set(sessions.map((item) => item.initiator_iqn));
  const networks = (state.discovery?.targets || []).flatMap((target) => target.auth_networks || []);
  entries.forEach((item) => item.startsWith("iqn.") ? iqns.add(item) : addExactIpv4(ips, item));
  networks.forEach((item) => addExactIpv4(ips, item));
  $("#ip-candidates").innerHTML = [...ips].filter(Boolean).sort().map((item) => `<option value="${esc(item)}"></option>`).join("");
  $("#iqn-candidates").innerHTML = [...iqns].filter(Boolean).sort().map((item) => `<option value="${esc(item)}"></option>`).join("");
}

function addExactIpv4(candidates, value) {
  const [address, prefix] = String(value).split("/");
  const octets = address.split(".").map(Number);
  const valid = octets.length === 4 && octets.every((item) => Number.isInteger(item) && item >= 0 && item <= 255);
  if (valid && (prefix === undefined || prefix === "32")) candidates.add(address);
}

function renderNetwork() {
  const draft = state.draft;
  const portalOptions = (state.discovery?.portals || []).flatMap((portal) => portal.listen)
    .filter((item) => item.address.includes("."))
    .map((item) => `${item.address}:${item.port}`);
  const currentPortal = `${draft.portal.address}:${draft.portal.port}`;
  $("#network-form").innerHTML = `
    ${field("Allowed source CIDR", "network-cidr", draft.allowed_source_cidr, "CIDR обязан быть canonical IPv4 network.")}
    <div class="field"><label for="network-portal">iSCSI portal</label><select id="network-portal">${options(portalOptions, currentPortal)}</select><p class="help">Только listen addresses из TrueNAS.</p></div>
    ${field("Publisher management IP", "admin-ip", draft.admin_api.allowed_source_ip, "Точный IP Publisher PC для Admin API.", "text", "ip-candidates")}
    ${field("Admin token digest", "admin-digest", draft.admin_api.token_digest, "Можно вставить digest или сгенерировать новый token.")}
    <div class="field full"><button id="generate-admin-token" type="button" class="secondary">Сгенерировать admin token</button></div>
    ${field("Release prefix", "release-prefix", draft.release_management.prefix)}
    ${field("Timezone", "release-timezone", draft.release_management.timezone)}
  `;
  bindInput("#network-cidr", (value) => draft.allowed_source_cidr = value);
  bindInput("#admin-ip", (value) => draft.admin_api.allowed_source_ip = value);
  bindInput("#admin-digest", (value) => draft.admin_api.token_digest = value);
  bindInput("#release-prefix", (value) => draft.release_management.prefix = value);
  bindInput("#release-timezone", (value) => draft.release_management.timezone = value);
  $("#network-portal").addEventListener("change", (event) => {
    const [address, port] = event.target.value.split(":");
    draft.portal = { address, port: Number(port) };
    syncYamlFromDraft();
  });
  $("#generate-admin-token").addEventListener("click", () => generateConfiguredToken("admin"));
}

function renderPublisher() {
  const publisher = state.draft.publisher;
  const targetOptions = availableTargets();
  const associations = eligibleAssociationsFor(publisher.target_iqn);
  const extentById = mapBy(state.discovery?.extents || [], "id");
  const rows = Object.entries(publisher.volumes).map(([name, volume]) => {
    const associationValue = `${volume.extent_id}:${volume.lun}`;
    const choices = associations.map((item) => `${item.extent_id}:${item.lun}`);
    const extent = extentById[volume.extent_id] || {};
    return `<div class="volume-card" data-publisher-volume="${esc(name)}">
      ${miniField("Logical name", "volume-name", name)}
      <div class="field"><label>Extent / LUN</label><select class="publisher-association">${options(choices, associationValue, associationLabel)}</select></div>
      ${miniField("Dataset", "publisher-dataset", volume.dataset, "text", true)}
      <button type="button" class="danger remove-publisher-volume" title="Удалить">Удалить</button>
      <p class="help field full">${esc(extent.name || "extent")} · NAA ${esc(extent.naa || "—")} · serial ${esc(extent.serial || "—")}</p>
    </div>`;
  }).join("");
  $("#publisher-form").innerHTML = `
    <section class="card">
      <div class="section-grid">
        ${field("Source IP", "publisher-ip", publisher.source_ip, "SAN IP Publisher PC.", "text", "ip-candidates")}
        ${field("Initiator IQN", "publisher-iqn", publisher.initiator_iqn, "Предлагается из initiator groups/sessions.", "text", "iqn-candidates")}
        <div class="field"><label for="publisher-target">Target IQN</label><select id="publisher-target">${options(targetOptions, publisher.target_iqn)}</select></div>
      </div>
      <div class="volume-list volume-table publisher-volume-table">
        ${rows ? '<div class="volume-table-header publisher-columns" aria-hidden="true"><span>Volume</span><span>Extent / LUN</span><span>Dataset</span><span></span></div>' : ''}
        ${rows || '<p class="empty-state">Выберите target и заполните его associations.</p>'}
      </div>
    </section>`;
  bindInput("#publisher-ip", (value) => publisher.source_ip = value);
  bindInput("#publisher-iqn", (value) => publisher.initiator_iqn = value);
  $("#publisher-target").addEventListener("change", (event) => {
    publisher.target_iqn = event.target.value;
    syncYamlFromDraft();
    renderPublisher();
  });
  $$("[data-publisher-volume]").forEach((row) => bindPublisherVolumeRow(row, extentById));
}

function bindPublisherVolumeRow(row, extentById) {
  const oldName = row.dataset.publisherVolume;
  row.querySelector(".volume-name").addEventListener("change", (event) => {
    const newName = event.target.value.trim();
    if (!newName || newName === oldName) return;
    const value = state.draft.publisher.volumes[oldName];
    delete state.draft.publisher.volumes[oldName];
    state.draft.publisher.volumes[newName] = value;
    syncYamlFromDraft();
    renderPublisher();
    renderClients();
  });
  row.querySelector(".publisher-association").addEventListener("change", (event) => {
    const [extentId, lun] = event.target.value.split(":").map(Number);
    const volume = state.draft.publisher.volumes[oldName];
    volume.extent_id = extentId;
    volume.lun = lun;
    volume.dataset = extentById[extentId]?.disk || "";
    syncYamlFromDraft();
    renderPublisher();
  });
  row.querySelector(".remove-publisher-volume").addEventListener("click", () => {
    delete state.draft.publisher.volumes[oldName];
    Object.values(state.draft.clients).forEach((client) => delete client.volumes[oldName]);
    syncYamlFromDraft();
    renderPublisher();
    renderClients();
  });
}

function fillPublisherFromTarget() {
  const publisher = state.draft.publisher;
  const extentById = mapBy(state.discovery?.extents || [], "id");
  const oldByExtent = Object.fromEntries(Object.entries(publisher.volumes).map(([name, value]) => [value.extent_id, [name, value]]));
  const next = {};
  eligibleAssociationsFor(publisher.target_iqn).forEach((association, index) => {
    const extent = extentById[association.extent_id];
    if (!extent || extent.type !== "DISK" || extent.locked !== false || !extent.disk) return;
    const existing = oldByExtent[association.extent_id];
    const name = existing?.[0] || uniqueName(slug(extent.name) || `volume-${index + 1}`, next);
    next[name] = { dataset: extent.disk, extent_id: association.extent_id, lun: association.lun };
  });
  publisher.volumes = next;
  syncYamlFromDraft();
  renderPublisher();
  renderClients();
}

function renderClients() {
  const targets = availableTargets();
  const cards = Object.entries(state.draft.clients).map(([name, client]) => {
    const volumeRows = Object.entries(client.volumes).map(([volumeName, volume]) => clientVolumeRow(name, client, volumeName, volume)).join("");
    return `<section class="client-card" data-client="${esc(name)}">
      <div class="card-heading"><h3>${esc(name)}</h3><div class="button-row"><button type="button" class="secondary fill-client">Заполнить из target</button><button type="button" class="danger remove-client">Удалить</button></div></div>
      <div class="section-grid">
        ${miniField("Client name", "client-name", name)}
        ${miniField("Source IP", "client-ip", client.source_ip, "text", false, "ip-candidates")}
        ${miniField("Initiator IQN", "client-iqn", client.initiator_iqn, "text", false, "iqn-candidates")}
        <div class="field"><label>Target IQN</label><select class="client-target">${options(targets, client.target_iqn)}</select></div>
        ${miniField("Token digest", "client-digest", client.token_digest)}
        <div class="field"><label>&nbsp;</label><button type="button" class="secondary generate-client-token">Сгенерировать client token</button></div>
      </div>
      <div class="volume-list volume-table client-volume-table">
        ${volumeRows ? '<div class="volume-table-header client-columns" aria-hidden="true"><span>Master volume</span><span>Extent / LUN</span><span>Clone parent</span><span>Letter</span><span>Label</span><span></span></div>' : ''}
        ${volumeRows || '<p class="empty-state">У клиента пока нет LUN mappings.</p>'}
      </div>
    </section>`;
  }).join("");
  $("#clients-form").innerHTML = cards || '<section class="card empty-state">Добавьте хотя бы одного клиента.</section>';
  $$("[data-client]").forEach(bindClientCard);
}

function clientVolumeRow(clientName, client, volumeName, volume) {
  const master = state.draft.publisher.volumes[volumeName];
  const associationValue = `${volume.extent_id}:${volume.lun}`;
  const associationChoices = eligibleAssociationsFor(client.target_iqn).map((item) => `${item.extent_id}:${item.lun}`);
  const masterNames = Object.keys(state.draft.publisher.volumes);
  const pool = master?.dataset?.split("/", 1)[0] || "";
  const parents = (state.discovery?.datasets || [])
    .filter((item) => item.type === "FILESYSTEM" && item.locked === false && item.id.split("/", 1)[0] === pool)
    .map((item) => item.id);
  return `<div class="volume-card client-volume" data-client-volume="${esc(volumeName)}">
    <div class="field"><label>Master volume</label><select class="client-master">${options(masterNames, volumeName)}</select></div>
    <div class="field"><label>Extent / LUN</label><select class="client-association">${options(associationChoices, associationValue, associationLabel)}</select></div>
    <div class="field"><label>Clone parent</label><select class="clone-parent">${options(parents, volume.clone_parent || client.clone_parent || "")}</select></div>
    ${miniField("Letter", "drive-letter", volume.drive_letter)}
    ${miniField("Label", "volume-label", volume.label)}
    <button type="button" class="danger remove-client-volume">Удалить</button>
    <div class="field client-override"><label>Windows UniqueId override</label><input class="unique-id-override" type="text" value="${esc(volume.windows_unique_id_override || "")}"></div>
  </div>`;
}

function bindClientCard(card) {
  const clientName = card.dataset.client;
  const client = state.draft.clients[clientName];
  card.querySelector(".client-name").addEventListener("change", (event) => {
    const newName = event.target.value.trim();
    if (!newName || newName === clientName) return;
    delete state.draft.clients[clientName];
    state.draft.clients[newName] = client;
    syncYamlFromDraft();
    renderClients();
  });
  bindWithin(card, ".client-ip", (value) => client.source_ip = value);
  bindWithin(card, ".client-iqn", (value) => client.initiator_iqn = value);
  bindWithin(card, ".client-digest", (value) => client.token_digest = value);
  card.querySelector(".client-target").addEventListener("change", (event) => {
    client.target_iqn = event.target.value;
    syncYamlFromDraft();
    renderClients();
  });
  card.querySelector(".fill-client").addEventListener("click", () => fillClientFromTarget(clientName));
  card.querySelector(".remove-client").addEventListener("click", () => {
    delete state.draft.clients[clientName];
    syncYamlFromDraft();
    renderClients();
  });
  card.querySelector(".generate-client-token").addEventListener("click", () => generateConfiguredToken("client", clientName));
  card.querySelectorAll("[data-client-volume]").forEach((row) => bindClientVolumeRow(row, clientName));
}

function bindClientVolumeRow(row, clientName) {
  const oldName = row.dataset.clientVolume;
  const client = state.draft.clients[clientName];
  const volume = client.volumes[oldName];
  row.querySelector(".client-master").addEventListener("change", (event) => {
    const newName = event.target.value;
    delete client.volumes[oldName];
    client.volumes[newName] = volume;
    syncYamlFromDraft();
    renderClients();
  });
  row.querySelector(".client-association").addEventListener("change", (event) => {
    const [extentId, lun] = event.target.value.split(":").map(Number);
    volume.extent_id = extentId;
    volume.lun = lun;
    syncYamlFromDraft();
  });
  row.querySelector(".clone-parent").addEventListener("change", (event) => { volume.clone_parent = event.target.value; syncYamlFromDraft(); });
  row.querySelector(".drive-letter").addEventListener("input", (event) => { volume.drive_letter = event.target.value.toUpperCase(); syncYamlFromDraft(); });
  row.querySelector(".volume-label").addEventListener("input", (event) => { volume.label = event.target.value; syncYamlFromDraft(); });
  row.querySelector(".unique-id-override").addEventListener("input", (event) => {
    if (event.target.value) volume.windows_unique_id_override = event.target.value;
    else delete volume.windows_unique_id_override;
    syncYamlFromDraft();
  });
  row.querySelector(".remove-client-volume").addEventListener("click", () => {
    delete client.volumes[oldName];
    syncYamlFromDraft();
    renderClients();
  });
}

function fillClientFromTarget(clientName) {
  const client = state.draft.clients[clientName];
  const oldByExtent = Object.fromEntries(Object.entries(client.volumes).map(([name, value]) => [value.extent_id, [name, value]]));
  const masterNames = Object.keys(state.draft.publisher.volumes);
  const used = new Set();
  const next = {};
  eligibleAssociationsFor(client.target_iqn).forEach((association, index) => {
    const existing = oldByExtent[association.extent_id];
    const volumeName = existing?.[0] || masterNames.find((name) => !used.has(name));
    if (!volumeName) return;
    used.add(volumeName);
    const master = state.draft.publisher.volumes[volumeName];
    const parent = (state.discovery?.datasets || []).find((item) => item.type === "FILESYSTEM" && item.locked === false && item.id.split("/", 1)[0] === master.dataset.split("/", 1)[0]);
    next[volumeName] = existing?.[1] || {
      extent_id: association.extent_id,
      lun: association.lun,
      drive_letter: String.fromCharCode(83 + index),
      label: `GAMES_${volumeName.toUpperCase()}`.slice(0, 32),
      clone_parent: parent?.id || "",
    };
    next[volumeName].extent_id = association.extent_id;
    next[volumeName].lun = association.lun;
  });
  client.volumes = next;
  syncYamlFromDraft();
  renderClients();
}

function addClient() {
  const index = Object.keys(state.draft.clients).length + 1;
  const name = uniqueName(`client-${index}`, state.draft.clients);
  state.draft.clients[name] = {
    source_ip: "",
    initiator_iqn: "",
    target_iqn: "",
    token_digest: digestPlaceholder(),
    volumes: {},
  };
  syncYamlFromDraft();
  renderClients();
}

async function generateConfiguredToken(kind, clientName = null) {
  try {
    const result = await api("/v1/configurator/tokens", { method: "POST", body: JSON.stringify({ kind }) });
    if (kind === "admin") state.draft.admin_api.token_digest = result.token_digest;
    else state.draft.clients[clientName].token_digest = result.token_digest;
    syncYamlFromDraft();
    renderNetwork();
    renderClients();
    const input = $("#raw-token");
    input.value = result.token;
    $("#token-dialog").showModal();
    input.focus();
    input.select();
  } catch (error) {
    setGlobalMessage(error.message, "error");
  }
}

async function validateYaml(applyToForms = false) {
  if (state.discovery === null) {
    setValidation("Discovery недоступен: проверка live topology заблокирована.", "error");
    return null;
  }
  setValidation("Проверка live topology…");
  try {
    const result = await api("/v1/configurator/config/validate", {
      method: "POST",
      body: JSON.stringify({ base_revision: state.baseRevision, yaml: $("#yaml-editor").value }),
    });
    $("#yaml-editor").value = result.yaml;
    state.yamlDirty = false;
    if (applyToForms) {
      state.draft = result.config;
      renderAll();
    }
    const warning = result.warnings?.length ? ` Предупреждения: ${result.warnings.join("; ")}` : "";
    setValidation(`Конфигурация валидна.${warning}`, result.warnings?.length ? "" : "good");
    return result;
  } catch (error) {
    setValidation(`${error.code}: ${error.message}`, "error");
    throw error;
  }
}

async function saveConfig() {
  if (state.discovery === null) {
    setValidation("Discovery недоступен: сохранение config.yaml заблокировано.", "error");
    return;
  }
  $("#save-button").disabled = true;
  setValidation("Повторная проверка и атомарное сохранение…");
  try {
    const result = await api("/v1/configurator/config", {
      method: "PUT",
      body: JSON.stringify({ base_revision: state.baseRevision, yaml: $("#yaml-editor").value }),
    });
    state.baseRevision = result.source_revision;
    state.status.saved_revision = result.saved_revision;
    state.status.source_revision = result.source_revision;
    state.status.restart_required = result.restart_required;
    const validated = await api("/v1/configurator/config");
    state.draft = validated.config;
    $("#yaml-editor").value = validated.yaml;
    state.yamlDirty = false;
    renderAll();
    setValidation(`Сохранено: ${result.saved_revision}. Требуется restart Custom App.`, "good");
  } catch (error) {
    setValidation(`${error.code}: ${error.message}`, "error");
    if (error.code === "CONFIG_CHANGED") await loadApplication();
  } finally {
    setTopologyActionsEnabled(state.discovery !== null);
  }
}

async function refreshDiscovery(announceSuccess = true) {
  state.discovery = null;
  setTopologyActionsEnabled(false);
  $("#connection-badge").textContent = "Обновление…";
  $("#connection-badge").className = "badge neutral";
  try {
    state.discovery = await api("/v1/configurator/discovery");
    if (state.needsDiscoveryDefaults) {
      state.draft = defaultDraft();
      $("#yaml-editor").value = yamlDump(state.draft);
      state.needsDiscoveryDefaults = false;
    }
    renderAll();
    setGlobalMessage(announceSuccess ? "Discovery обновлён без mutations." : "", "good");
    return true;
  } catch (error) {
    if (error.code === "UNAUTHORIZED") {
      state.csrf = null;
      $("#login-view").hidden = false;
      $("#app-view").hidden = true;
      return false;
    }
    renderAll();
    setGlobalMessage(`Discovery unavailable: ${error.message}`, "error");
    return false;
  }
}

function switchPanel(panel) {
  if (state.activePanel === "yaml" && panel !== "yaml" && state.yamlDirty) {
    if (!window.confirm("Raw YAML ещё не применён к формам. Отменить его изменения?")) return;
    $("#yaml-editor").value = yamlDump(state.draft);
    state.yamlDirty = false;
  }
  state.activePanel = panel;
  $$(".nav-item").forEach((item) => item.classList.toggle("active", item.dataset.panel === panel));
  $$(".panel").forEach((item) => item.classList.toggle("active", item.id === `panel-${panel}`));
}

function syncYamlFromDraft() {
  $("#yaml-editor").value = yamlDump(state.draft);
  state.yamlDirty = false;
  state.needsDiscoveryDefaults = false;
  setValidation("Draft изменён; выполните проверку перед сохранением.");
}

function yamlDump(value, depth = 0) {
  const indent = "  ".repeat(depth);
  if (Array.isArray(value)) return value.map((item) => `${indent}- ${yamlScalar(item)}`).join("\n");
  if (value && typeof value === "object") {
    return Object.entries(value).map(([key, item]) => {
      if (item && typeof item === "object") return `${indent}${yamlKey(key)}:\n${yamlDump(item, depth + 1)}`;
      return `${indent}${yamlKey(key)}: ${yamlScalar(item)}`;
    }).join("\n") + (depth === 0 ? "\n" : "");
  }
  return `${indent}${yamlScalar(value)}`;
}

function yamlKey(value) {
  return /^[a-zA-Z0-9_.-]+$/.test(value) ? value : JSON.stringify(value);
}

function yamlScalar(value) {
  if (value === null) return "null";
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  const text = String(value);
  return /^[a-zA-Z0-9_./-]+$/.test(text) && !["true", "false", "null"].includes(text.toLowerCase()) ? text : JSON.stringify(text);
}

function field(label, id, value, help = "", type = "text", list = "") {
  return `<div class="field"><label for="${id}">${esc(label)}</label><input id="${id}" type="${type}" value="${esc(value)}" ${list ? `list="${list}"` : ""}>${help ? `<p class="help">${esc(help)}</p>` : ""}</div>`;
}

function miniField(label, className, value, type = "text", readonly = false, list = "") {
  return `<div class="field"><label>${esc(label)}</label><input class="${className}" type="${type}" value="${esc(value)}" ${readonly ? "readonly" : ""} ${list ? `list="${list}"` : ""}></div>`;
}

function options(values, selected, labeler = (value) => value) {
  const unique = [...new Set([selected, ...values].filter((value) => value !== undefined && value !== null))];
  return unique.map((value) => `<option value="${esc(value)}" ${value === selected ? "selected" : ""}>${esc(labeler(value))}</option>`).join("");
}

function associationLabel(value) {
  const [extentId, lun] = String(value).split(":");
  const extent = (state.discovery?.extents || []).find((item) => item.id === Number(extentId));
  return `LUN ${lun} · #${extentId} · ${extent?.name || "extent"} · ${extent?.disk || "no disk"}`;
}

function associationsFor(targetIqn) {
  return (state.discovery?.associations || []).filter((item) => item.target_iqn === targetIqn).sort((a, b) => a.lun - b.lun);
}

function eligibleAssociationsFor(targetIqn) {
  const extents = mapBy(state.discovery?.extents || [], "id");
  return associationsFor(targetIqn).filter((item) => {
    const extent = extents[item.extent_id];
    return extent?.type === "DISK" && extent.locked === false && Boolean(extent.disk);
  });
}

function availableTargets() {
  return (state.discovery?.targets || [])
    .filter((item) => item.mode === "ISCSI" || item.mode === "BOTH")
    .map((item) => item.iqn);
}

function bindInput(selector, update) {
  $(selector).addEventListener("input", (event) => { update(event.target.value); syncYamlFromDraft(); });
}

function bindWithin(parent, selector, update) {
  parent.querySelector(selector).addEventListener("input", (event) => { update(event.target.value); syncYamlFromDraft(); });
}

function mapBy(items, key) {
  return Object.fromEntries(items.map((item) => [item[key], item]));
}

function slug(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9._-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 48);
}

function uniqueName(preferred, mapping) {
  let candidate = preferred;
  let suffix = 2;
  while (Object.hasOwn(mapping, candidate)) candidate = `${preferred}-${suffix++}`;
  return candidate;
}

function downloadYaml() {
  const blob = new Blob([$("#yaml-editor").value], { type: "application/yaml" });
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = "config.yaml";
  link.click();
  URL.revokeObjectURL(url);
}

async function logout() {
  try { await api("/v1/configurator/session", { method: "DELETE" }); } catch (_) { /* local session only */ }
  state.csrf = null;
  state.draft = null;
  state.discovery = null;
  state.needsDiscoveryDefaults = false;
  $("#app-view").hidden = true;
  $("#login-view").hidden = false;
  $("#login-token").focus();
}

$("#login-form").addEventListener("submit", login);
$("#logout-button").addEventListener("click", logout);
$("#refresh-button").addEventListener("click", () => refreshDiscovery());
$("#fill-publisher").addEventListener("click", fillPublisherFromTarget);
$("#add-client").addEventListener("click", addClient);
$("#validate-button").addEventListener("click", () => validateYaml(false).catch(() => {}));
$("#apply-yaml").addEventListener("click", () => validateYaml(true).catch(() => {}));
$("#save-button").addEventListener("click", saveConfig);
$("#download-yaml").addEventListener("click", downloadYaml);
$("#yaml-editor").addEventListener("input", () => {
  state.yamlDirty = true;
  state.needsDiscoveryDefaults = false;
  setValidation("Raw YAML изменён; примените его к формам или сохраните после проверки.");
});
$("#token-dialog").addEventListener("close", () => { $("#raw-token").value = ""; });
$("#copy-token").addEventListener("click", async () => { await navigator.clipboard.writeText($("#raw-token").value); $("#copy-token").textContent = "Скопировано"; });
$$(`.nav-item`).forEach((button) => button.addEventListener("click", () => switchPanel(button.dataset.panel)));
$("#login-token").focus();
loadApplication();
