import { useCallback, useEffect, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  Divider,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  MenuItem,
  TextField,
  Typography,
} from "@mui/material";
import KeyIcon from "@mui/icons-material/Key";
import OpenInNewIcon from "@mui/icons-material/OpenInNew";
import PauseCircleIcon from "@mui/icons-material/PauseCircle";
import PlayCircleIcon from "@mui/icons-material/PlayCircle";
import ContentCopyIcon from "@mui/icons-material/ContentCopy";

const CONSOLES = {
  anthropic: "https://console.anthropic.com/settings/keys",
  deepseek: "https://platform.deepseek.com/api_keys",
  jev: "https://console.typesafe.ai/keys",
  subq: "https://console.subq.ai/",
  gemini: "https://aistudio.google.com/app/apikey",
};
const ROTATE = {
  deepseek: "./scripts/rotate-api-keys.sh",
  jev: "./scripts/rotate-api-keys.sh",
  anthropic: "./scripts/rotate-provider-keys.sh",
  subq: "./scripts/rotate-provider-keys.sh",
};
const APPLY = "./scripts/settings-apply.sh --apply --yes";
const SETUP_STEPS = [
  "Provider key setup",
  "1. One-time host applier: ./scripts/key-request-install.sh",
  "2. Open https://localhost:5099/app/#settings (or Overview -> Provider keys, or a provider row -> set key)",
  "3. Choose the provider, paste the key, type the provider id, click Queue key",
  "4. The host writes .env.local (0600) and restarts opencode-web; hard-refresh if the PWA shell is stale",
  "5. If the provider is paused, resume/clear it first; otherwise settings-apply will comment the new key",
].join("\n");

export default function Settings() {
  const [doc, setDoc] = useState(null);
  const [error, setError] = useState("");
  const [confirm, setConfirm] = useState("");
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState("");
  const [reloadKey, setReloadKey] = useState(0);
  const [keyProvider, setKeyProvider] = useState("");
  const [newKey, setNewKey] = useState("");
  const [keyConfirm, setKeyConfirm] = useState("");
  const [keyStatus, setKeyStatus] = useState("");
  const [keyBusy, setKeyBusy] = useState(false);

  const load = useCallback(async () => {
    try {
      const r = await fetch("/api/settings", { headers: { accept: "application/json" } });
      if (!r.ok) throw new Error("HTTP " + r.status);
      setDoc(await r.json());
      setError("");
    } catch (e) {
      setError("settings unavailable: " + (e.message || String(e)));
    }
  }, []);

  useEffect(() => {
    load();
  }, [load, reloadKey]);

  const copy = async (text) => {
    try {
      await navigator.clipboard.writeText(text);
      setStatus("copied: " + text);
    } catch {
      setStatus("copy failed — select and copy: " + text);
    }
  };

  const act = async (id, action) => {
    if (confirm.trim() !== id) {
      setStatus('type "' + id + '" in the confirm box to ' + action);
      return;
    }
    setBusy(id);
    setStatus("");
    try {
      const r = await fetch("/api/settings/provider", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id, action, confirm }),
      });
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || "request failed");
      if (d.settings) setDoc(d.settings);
      setConfirm("");
      setStatus(
        action + " " + id + " recorded" + (d.hostActionRequired ? " — now run: " + (d.hostCommand || APPLY) : "")
      );
      setReloadKey((k) => k + 1);
    } catch (e) {
      setStatus("error: " + (e.message || String(e)));
    } finally {
      setBusy("");
    }
  };

  const queueKey = async () => {
    if (keyConfirm.trim() !== keyProvider) {
      setKeyStatus("type the provider id to confirm");
      return;
    }
    setKeyBusy(true);
    setKeyStatus("");
    try {
      const r = await fetch("/api/settings/key", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ id: keyProvider, key: newKey, confirm: keyConfirm }),
      });
      const d = await r.json();
      if (!d.ok) throw new Error(d.error || "queue failed");
      setNewKey("");
      setKeyConfirm("");
      setKeyStatus("queued " + d.env + " (" + d.len + " chars); " + (d.note || "host applier writes .env.local; restart required"));
      setReloadKey((k) => k + 1);
    } catch (e) {
      setKeyStatus("error: " + (e.message || String(e)));
    } finally {
      setKeyBusy(false);
    }
  };

  const providers = doc?.providers || [];
  const pending = providers.filter((p) => p.pendingApply);

  useEffect(() => {
    if (!keyProvider && providers.length) {
      const p = providers.find((x) => x.envVar);
      if (p) setKeyProvider(p.id);
    }
  }, [providers, keyProvider]);

  return (
    <Box>
      <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography component="h1" variant="h4">Settings</Typography>
          <Typography variant="body2" color="text.secondary">
            Pause or resume providers and see which keys are present. Secrets are never shown or entered here.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
          <Chip size="small" variant="outlined" label={`${providers.length} providers`} />
          <Chip size="small" color={pending.length ? "warning" : "default"} label={`${pending.length} pending host apply`} />
        </Stack>
      </Stack>

      <Alert severity="info" sx={{ mb: 2 }}>
        <Typography variant="body2">
          The dashboard runs inside the container, where <code>.env.local</code> is masked. Pause writes desired
          state; the host applier comments the provider&apos;s env-key line, logs it out, recreates the web container,
          and verifies the key is gone.
        </Typography>
        <Stack direction="row" spacing={1} sx={{ mt: 1 }} useFlexGap flexWrap="wrap">
          <code>{APPLY}</code>
          <Button size="small" startIcon={<ContentCopyIcon />} onClick={() => copy(APPLY)}>
            Copy
          </Button>
        </Stack>
      </Alert>

      {error && <Alert severity="error" sx={{ mb: 2 }}>{error}</Alert>}
      {status && (
        <Alert
          severity={status.startsWith("error") ? "error" : "success"}
          role={status.startsWith("error") ? "alert" : "status"}
          sx={{ mb: 2 }}
        >
          {status}
        </Alert>
      )}

      <Card sx={{ mb: 2 }}>
        <CardContent>
          <Stack direction={{ xs: "column", sm: "row" }} spacing={2} alignItems={{ sm: "center" }} sx={{ mb: 1 }}>
            <TextField
              size="small"
              label="Confirm provider id"
              value={confirm}
              autoComplete="off"
              spellCheck={false}
              onChange={(e) => setConfirm(e.target.value)}
              helperText="Type the provider id to enable its pause/resume action."
              sx={{ maxWidth: 260 }}
            />
            {pending.length > 0 && (
              <Button variant="contained" onClick={() => copy(APPLY)} startIcon={<ContentCopyIcon />}>
                Copy host apply
              </Button>
            )}
          </Stack>
          <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow>
                <TableCell>provider</TableCell>
                <TableCell>state</TableCell>
                <TableCell>key</TableCell>
                <TableCell>auth</TableCell>
                <TableCell>policy</TableCell>
                <TableCell align="right">actions</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {providers.map((p) => (
                <TableRow key={p.id}>
                  <TableCell>
                    <Typography variant="body2" fontWeight={700}>{p.id}</Typography>
                    {!p.inConfig && <Typography variant="caption" color="text.secondary">env-only</Typography>}
                  </TableCell>
                  <TableCell>
                    <Chip
                      size="small"
                      color={p.paused ? "warning" : p.state === "active" ? "success" : "default"}
                      label={p.state}
                      variant={p.paused ? "filled" : "outlined"}
                    />
                  </TableCell>
                  <TableCell>
                    <Typography variant="body2" color={p.envKey ? "success.main" : p.keyQueued ? "warning.main" : "text.secondary"}>
                      {p.envKey ? "present" : p.keyQueued ? "queued (host apply)" : "absent"}
                    </Typography>
                    <Typography variant="caption" color="text.secondary">{p.envVar || "—"}</Typography>
                  </TableCell>
                  <TableCell>{p.authEntry ? "yes" : "no"}</TableCell>
                  <TableCell>{p.policy}</TableCell>
                  <TableCell align="right">
                    <Stack direction="row" spacing={0.5} justifyContent="flex-end" useFlexGap flexWrap="wrap">
                      <Button
                        size="small"
                        variant={p.paused ? "contained" : "outlined"}
                        color={p.paused ? "success" : "warning"}
                        startIcon={p.paused ? <PlayCircleIcon /> : <PauseCircleIcon />}
                        disabled={busy === p.id}
                        onClick={() => act(p.id, p.paused ? "resume" : "pause")}
                      >
                        {p.paused ? "resume" : "pause"}
                      </Button>
                      {CONSOLES[p.id] && (
                        <Button size="small" endIcon={<OpenInNewIcon />} href={CONSOLES[p.id]} target="_blank" rel="noopener">
                          console
                        </Button>
                      )}
                      {ROTATE[p.id] && (
                        <Button size="small" startIcon={<ContentCopyIcon />} onClick={() => copy(ROTATE[p.id])}
                          title="copies the rotate command; it does not run it">
                          copy cmd
                        </Button>
                      )}
                      {p.envVar && (
                        <Button size="small" variant="text" onClick={() => {
                          setKeyProvider(p.id);
                          const box = document.getElementById("set-key");
                          if (box) box.scrollIntoView({ behavior: "smooth" });
                          const f = document.getElementById("new-key");
                          if (f) f.focus();
                        }}>
                          set key
                        </Button>
                      )}
                    </Stack>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          </TableContainer>
        </CardContent>
      </Card>

      <Card id="set-key" sx={{ mb: 2 }}>
        <CardContent>
          <Stack direction="row" spacing={1} alignItems="center" sx={{ mb: 1 }}>
            <KeyIcon fontSize="small" />
            <Typography variant="h6">Set a key</Typography>
          </Stack>
          <Alert severity="info" sx={{ mb: 1.5 }}>
            Paste a key from the vendor console. It is sent once over HTTPS to a 0600 host queue and is not shown
            again; the host applier writes <code>.env.local</code> and restarts the web container (one-time install:
            <code>./scripts/key-request-install.sh</code>). If the provider is paused, resume/clear it first, or the
            next settings-apply will comment the new key.
          </Alert>
          <Stack direction={{ xs: "column", sm: "row" }} spacing={1} useFlexGap flexWrap="wrap" alignItems={{ sm: "center" }}>
            <TextField select size="small" label="Provider" value={keyProvider} onChange={(e) => setKeyProvider(e.target.value)} sx={{ minWidth: 190 }}>
              {providers.filter((p) => p.envVar).map((p) => (
                <MenuItem key={p.id} value={p.id}>{p.id} ({p.envVar})</MenuItem>
              ))}
            </TextField>
            <TextField id="new-key" size="small" type="password" label="New key" value={newKey}
              onChange={(e) => setNewKey(e.target.value)} autoComplete="new-password" sx={{ minWidth: 240 }} />
            <TextField size="small" label="Confirm provider for key" value={keyConfirm}
              onChange={(e) => setKeyConfirm(e.target.value)} autoComplete="off" spellCheck={false} sx={{ minWidth: 210 }} />
            <Button variant="contained" disabled={keyBusy || !keyProvider || !newKey || keyConfirm.trim() !== keyProvider}
              onClick={queueKey}>
              Queue key
            </Button>
          </Stack>
          <Typography variant="body2" color="text.secondary" sx={{ mt: 1 }}>
            One-time host applier: <code>./scripts/key-request-install.sh</code>. Then choose a provider, paste,
            confirm, and <b>Queue key</b>. The host writes <code>.env.local</code> and restarts; hard-refresh if the
            PWA shell is stale. Paused providers must be resumed first.
          </Typography>
          <Button size="small" startIcon={<ContentCopyIcon />} sx={{ mt: 1 }} onClick={() => copy(SETUP_STEPS)}>
            copy setup steps
          </Button>
          {keyStatus && (
            <Alert severity={keyStatus.startsWith("error") ? "error" : "success"}
              role={keyStatus.startsWith("error") ? "alert" : "status"} sx={{ mt: 1.5 }}>
              {keyStatus}
            </Alert>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardContent>
          <Stack direction="row" spacing={1} alignItems="center" sx={{ mb: 1 }}>
            <KeyIcon fontSize="small" />
            <Typography variant="h6">Keys</Typography>
          </Stack>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
            Use the Set key form above to queue a key, or rotate at the console and run the matching script on the
            host. The new value is never displayed again.
          </Typography>
          <Divider sx={{ mb: 1 }} />
          <TableContainer>
          <Table size="small">
            <TableHead>
              <TableRow><TableCell>provider</TableCell><TableCell>env var</TableCell><TableCell>status</TableCell><TableCell>console</TableCell><TableCell>rotate</TableCell></TableRow>
            </TableHead>
            <TableBody>
              {providers.filter((p) => p.envVar || CONSOLES[p.id]).map((p) => (
                <TableRow key={p.id}>
                  <TableCell>{p.id}</TableCell>
                  <TableCell><code>{p.envVar || "—"}</code></TableCell>
                  <TableCell>{p.paused ? "paused" : p.envKey ? "present" : "absent"}</TableCell>
                  <TableCell>
                    {CONSOLES[p.id] ? (
                      <Button size="small" endIcon={<OpenInNewIcon />} href={CONSOLES[p.id]} target="_blank" rel="noopener">open</Button>
                    ) : "—"}
                  </TableCell>
                  <TableCell>
                    {ROTATE[p.id] ? (
                      <Button size="small" startIcon={<ContentCopyIcon />} onClick={() => copy(ROTATE[p.id])}>{ROTATE[p.id].split("/").pop()}</Button>
                    ) : "—"}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
          </TableContainer>
        </CardContent>
      </Card>
    </Box>
  );
}
