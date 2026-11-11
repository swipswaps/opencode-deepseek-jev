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

export default function Settings() {
  const [doc, setDoc] = useState(null);
  const [error, setError] = useState("");
  const [confirm, setConfirm] = useState("");
  const [status, setStatus] = useState("");
  const [busy, setBusy] = useState("");
  const [reloadKey, setReloadKey] = useState(0);

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

  const providers = doc?.providers || [];
  const pending = providers.filter((p) => p.pendingApply);

  return (
    <Box>
      <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h4">Settings</Typography>
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
                    <Typography variant="body2" color={p.envKey ? "success.main" : "text.secondary"}>
                      {p.envKey ? "present" : "absent"}
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
                        <Button size="small" startIcon={<ContentCopyIcon />} onClick={() => copy(ROTATE[p.id])}>
                          rotate cmd
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

      <Card>
        <CardContent>
          <Stack direction="row" spacing={1} alignItems="center" sx={{ mb: 1 }}>
            <KeyIcon fontSize="small" />
            <Typography variant="h6">Keys</Typography>
          </Stack>
          <Typography variant="body2" color="text.secondary" sx={{ mb: 1 }}>
            Key entry stays in the terminal or the provider console — a secret is never posted to this page. Rotate at
            the console, then run the matching script on the host; the new value never leaves <code>.env.local</code>.
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
