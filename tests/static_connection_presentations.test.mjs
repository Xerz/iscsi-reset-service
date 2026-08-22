import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync("src/iscsi_reset_service/static/app.js", "utf8");
const start = source.indexOf("function connectionLabel");
const end = source.indexOf("function updateLabel");
assert.notEqual(start, -1);
assert.notEqual(end, -1);

const context = { state: { dashboard: null } };
vm.runInNewContext(source.slice(start, end), context);

function assertPresentation(actual, label, kind) {
  assert.equal(actual.label, label);
  assert.equal(actual.kind, kind);
}

const clientSession = {
  initiator_addr: "10.20.40.100",
  initiator_iqn: "iqn.1991-05.com.microsoft:publisher",
  target_iqn: "iqn.2026-08.lab.games:chimera",
};
context.state.dashboard = {
  publisher: { connection_status: "conflict", matching_sessions: [clientSession] },
  clients: [
    {
      name: "chimera",
      connection_status: "connected",
      matching_sessions: [clientSession],
    },
  ],
};
assertPresentation(
  context.connectionPresentation("publisher", context.state.dashboard.publisher),
  "на общем ПК активна роль клиента «chimera» · iqn.2026-08.lab.games:chimera",
  "warning",
);

const masterSession = {
  ...clientSession,
  target_iqn: "iqn.2026-08.lab.games:master",
};
context.state.dashboard = {
  publisher: { connection_status: "connected", matching_sessions: [masterSession] },
  clients: [
    {
      name: "chimera",
      connection_status: "conflict",
      matching_sessions: [masterSession],
    },
  ],
};
assertPresentation(
  context.connectionPresentation("client", context.state.dashboard.clients[0], "chimera"),
  "на общем ПК активна роль Publisher · iqn.2026-08.lab.games:master",
  "warning",
);

const unknownSession = {
  ...masterSession,
  initiator_addr: "10.20.40.250",
};
context.state.dashboard = {
  publisher: { connection_status: "conflict", matching_sessions: [unknownSession] },
  clients: [],
};
assertPresentation(
  context.connectionPresentation("publisher", context.state.dashboard.publisher),
  "identity conflict",
  "error",
);
