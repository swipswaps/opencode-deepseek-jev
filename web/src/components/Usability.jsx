import { useEffect, useMemo, useState } from "react";
import {
  Accordion,
  AccordionDetails,
  AccordionSummary,
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  Divider,
  FormControl,
  InputLabel,
  LinearProgress,
  MenuItem,
  Select,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TextField,
  Typography,
} from "@mui/material";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import PlayArrowIcon from "@mui/icons-material/PlayArrow";
import OpenInNewIcon from "@mui/icons-material/OpenInNew";
import { useRemote } from "../useLive.js";

function num(v) {
  return v == null || Number.isNaN(Number(v)) ? "n/a" : String(v);
}

export default function Usability() {
  const auto = useRemote("/api/usability", 30000);
  const tasksDoc = useRemote("/api/usability/tasks", 3600000);
  const spec = tasksDoc.data || { tasks: [], sus_items: [] };
  const tasks = spec.tasks || [];

  const [participant, setParticipant] = useState("anonymous");
  const [phase, setPhase] = useState("idle"); // idle | task | next | sus | saved
  const [idx, setIdx] = useState(-1);
  const [startedAt, setStartedAt] = useState(0);
  const [tick, setTick] = useState(Date.now());
  const [results, setResults] = useState([]);
  const [difficulty, setDifficulty] = useState("");
  const [note, setNote] = useState("");
  const [sus, setSus] = useState(Array(10).fill(3));
  const [sessionNotes, setSessionNotes] = useState("");
  const [saved, setSaved] = useState(null);
  const [error, setError] = useState("");

  useEffect(() => {
    if (phase !== "task") return undefined;
    const t = setInterval(() => setTick(Date.now()), 200);
    return () => clearInterval(t);
  }, [phase]);

  const current = idx >= 0 ? tasks[idx] : null;
  const elapsed = phase === "task" ? Math.max(0, (tick - startedAt) / 1000) : 0;
  const last = results.length ? results[results.length - 1] : null;
  const shownTime = phase === "task" ? elapsed : last?.duration_s ?? 0;
  const progress = tasks.length ? Math.min(100, ((results.length) / tasks.length) * 100) : 0;
  const autoDoc = auto.data && auto.data.verdict ? auto.data : null;

  const automation = useMemo(
    () => ({
      verdict: autoDoc?.verdict || "n/a",
      effectiveness: num(autoDoc?.effectiveness),
      efficiency: autoDoc?.efficiency_s == null ? "n/a" : `${autoDoc.efficiency_s}s`,
      sus: num(autoDoc?.satisfaction_sus),
      failures: autoDoc?.fail_count || 0,
      axes: autoDoc?.axes || {},
      failuresList: autoDoc?.failures || [],
      caveat: autoDoc?.caveat || "",
    }),
    [autoDoc],
  );

  const start = () => {
    if (!tasks.length) return;
    setResults([]);
    setIdx(0);
    setStartedAt(Date.now());
    setTick(Date.now());
    setDifficulty("");
    setNote("");
    setError("");
    setSaved(null);
    setPhase("task");
  };

  const finish = (success) => {
    if (!current || phase !== "task") return;
    const secs = Math.round(((Date.now() - startedAt) / 1000) * 100) / 100;
    setResults((r) => [
      ...r,
      {
        id: current.id,
        success,
        duration_s: secs,
        difficulty: difficulty ? Number(difficulty) : null,
        note,
      },
    ]);
    setPhase("next");
  };

  const next = () => {
    if (idx + 1 < tasks.length) {
      setIdx(idx + 1);
      setStartedAt(Date.now());
      setTick(Date.now());
      setDifficulty("");
      setNote("");
      setPhase("task");
    } else {
      setPhase("sus");
    }
  };

  const submit = async () => {
    setError("");
    try {
      const res = await fetch("/api/usability/guided", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          participant: participant || "anonymous",
          notes: sessionNotes,
          tasks: results,
          sus,
        }),
      });
      const doc = await res.json();
      if (!doc || !doc.ok) throw new Error(doc?.error || "save failed");
      setSaved(doc.session);
      setPhase("saved");
    } catch (e) {
      setError(e.message || String(e));
    }
  };

  // useRemote has no refresh method; re-fetch after save by toggling the path.
  const [historyKey, setHistoryKey] = useState(0);
  const history = useRemote(`/api/usability/guided?limit=10&k=${historyKey}`, 30000);
  const sessions = history.data?.sessions || [];
  useEffect(() => {
    if (phase === "saved") setHistoryKey((k) => k + 1);
  }, [phase]);

  return (
    <Box>
      <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "flex-start", sm: "center" }} spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h4">Usability</Typography>
          <Typography variant="body2" color="text.secondary">
            A cited automated screen plus a guided human test. They are reported separately: a green screen is not a human result.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
          <Chip size="small" color={automation.verdict === "PASS" ? "success" : automation.verdict === "FAIL" ? "error" : "default"} label={`auto ${automation.verdict}`} />
          <Chip size="small" variant="outlined" label={`effectiveness ${automation.effectiveness}`} />
          <Chip size="small" variant="outlined" label={`SUS ${automation.sus}`} />
        </Stack>
      </Stack>

      <Alert severity="info" sx={{ mb: 2 }}>
        <Typography variant="body2">
          <b>Guided test:</b> open each goal, let the participant use the app, then record Done / Failed / Skip. The timer, difficulty, note and SUS are stored as human evidence.
        </Typography>
        <Typography variant="caption" color="text.secondary" component="div" sx={{ mt: 0.5 }}>
          Optional automation: <code>./scripts/usability-guide.sh --opener xdg</code> opens each page for you; use <code>--opener playwright</code> or <code>selenium</code> when available.
        </Typography>
      </Alert>

      <Box sx={{ display: "grid", gridTemplateColumns: { xs: "1fr", lg: "1.15fr .85fr" }, gap: 2 }}>
        <Card>
          <CardContent>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
              <Typography variant="h6">Guided human test</Typography>
              <Chip size="small" variant="outlined" label={`${results.length}/${tasks.length} recorded`} />
            </Stack>
            <LinearProgress variant="determinate" value={progress} sx={{ height: 6, borderRadius: 999, mb: 1.5 }} />

            {phase === "idle" && (
              <Stack spacing={1.5}>
                <TextField size="small" label="Participant label" value={participant} onChange={(e) => setParticipant(e.target.value)} helperText="Use a pseudonym; no personal data is needed." />
                <Button variant="contained" startIcon={<PlayArrowIcon />} onClick={start} disabled={!tasks.length}>
                  {tasks.length ? "Start guided test" : "Waiting for task script…"}
                </Button>
              </Stack>
            )}

            {(phase === "task" || phase === "next") && current && (
              <Stack spacing={1}>
                <Typography variant="overline" color="text.secondary">
                  Task {idx + 1} of {tasks.length} · {current.path}
                </Typography>
                <Typography variant="h6">{current.title}</Typography>
                <Typography variant="body2">{current.instruction}</Typography>
                <Typography variant="caption" color="text.secondary">
                  Success: {current.success}
                </Typography>
                <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap" alignItems="center">
                  <Button size="small" variant="outlined" endIcon={<OpenInNewIcon />} component="a" href={current.path} target="_blank" rel="noopener">
                    Open page
                  </Button>
                  <Typography variant="h5" sx={{ fontVariantNumeric: "tabular-nums", minWidth: 80 }}>
                    {Number(shownTime).toFixed(1)}s
                  </Typography>
                  {phase === "next" && last && (
                    <Chip size="small" color={last.success === true ? "success" : last.success === false ? "error" : "default"} label={last.success === true ? "recorded: done" : last.success === false ? "recorded: failed" : "recorded: skipped"} />
                  )}
                </Stack>
                <Stack direction={{ xs: "column", sm: "row" }} spacing={1}>
                  <FormControl size="small" sx={{ minWidth: 120 }}>
                    <InputLabel id="difficulty-label">Difficulty</InputLabel>
                    <Select labelId="difficulty-label" label="Difficulty" value={difficulty} onChange={(e) => setDifficulty(e.target.value)} disabled={phase !== "task"}>
                      <MenuItem value="">n/a</MenuItem>
                      {[1, 2, 3, 4, 5].map((v) => (
                        <MenuItem key={v} value={v}>{v}</MenuItem>
                      ))}
                    </Select>
                  </FormControl>
                  <TextField size="small" label="Note" value={note} onChange={(e) => setNote(e.target.value)} disabled={phase !== "task"} sx={{ flex: 1 }} />
                </Stack>
                {phase === "task" ? (
                  <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
                    <Button variant="contained" color="success" onClick={() => finish(true)}>Done</Button>
                    <Button variant="outlined" color="error" onClick={() => finish(false)}>Failed</Button>
                    <Button variant="text" onClick={() => finish(null)}>Skip</Button>
                  </Stack>
                ) : (
                  <Button variant="contained" onClick={next}>Next</Button>
                )}
              </Stack>
            )}

            {phase === "sus" && (
              <Stack spacing={1.25}>
                <Typography variant="h6">SUS questionnaire</Typography>
                <Typography variant="caption" color="text.secondary">
                  1 = strongly disagree, 5 = strongly agree.
                </Typography>
                {(spec.sus_items || []).map((item, i) => (
                  <Stack key={i} direction={{ xs: "column", sm: "row" }} spacing={1} alignItems={{ xs: "flex-start", sm: "center" }}>
                    <Typography variant="body2" sx={{ flex: 1 }}>{i + 1}. {item}</Typography>
                    <FormControl size="small" sx={{ minWidth: 84 }}>
                      <InputLabel id={`sus-${i}`}>Score</InputLabel>
                      <Select
                        labelId={`sus-${i}`}
                        label="Score"
                        value={sus[i]}
                        onChange={(e) => setSus((s) => s.map((v, j) => (j === i ? Number(e.target.value) : v)))}
                      >
                        {[1, 2, 3, 4, 5].map((v) => (
                          <MenuItem key={v} value={v}>{v}</MenuItem>
                        ))}
                      </Select>
                    </FormControl>
                  </Stack>
                ))}
                <TextField size="small" label="Session notes" multiline minRows={2} value={sessionNotes} onChange={(e) => setSessionNotes(e.target.value)} />
                {error && <Alert severity="error">{error}</Alert>}
                <Button variant="contained" onClick={submit}>Submit session</Button>
              </Stack>
            )}

            {phase === "saved" && saved && (
              <Alert severity="success">
                Saved session #{saved.id}: effectiveness {num(saved.effectiveness)}, median time {num(saved.efficiency_s)}s, SUS {num(saved.satisfaction_sus)}.
              </Alert>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardContent>
            <Typography variant="h6" sx={{ mb: 1 }}>Automated evidence</Typography>
            {!autoDoc && <Alert severity="info">No automated run yet. Run <code>./scripts/usability-suite.py --static-only</code>.</Alert>}
            {autoDoc && (
              <Stack spacing={1}>
                <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
                  <Chip size="small" label={`mode ${autoDoc.mode || "?"}`} />
                  <Chip size="small" color={autoDoc.fail_count ? "warning" : "success"} label={`${autoDoc.fail_count || 0} failures`} />
                  <Chip size="small" variant="outlined" label={`${autoDoc.skip_count || 0} skips`} />
                </Stack>
                <Table size="small">
                  <TableHead>
                    <TableRow><TableCell>axis</TableCell><TableCell align="right">pass</TableCell><TableCell align="right">fail</TableCell><TableCell align="right">skip</TableCell><TableCell align="right">score</TableCell></TableRow>
                  </TableHead>
                  <TableBody>
                    {Object.entries(automation.axes).map(([k, v]) => (
                      <TableRow key={k}>
                        <TableCell>{k}</TableCell>
                        <TableCell align="right">{v.pass}</TableCell>
                        <TableCell align="right">{v.fail}</TableCell>
                        <TableCell align="right">{v.skip}</TableCell>
                        <TableCell align="right">{num(v.score)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                {automation.failuresList.slice(0, 5).map((f) => (
                  <Typography key={`${f.axis}-${f.metric}`} variant="caption" color="error" component="div">
                    FAIL {f.axis}/{f.metric}: {f.detail}
                  </Typography>
                ))}
                <Typography variant="caption" color="text.secondary">{automation.caveat}</Typography>
              </Stack>
            )}
          </CardContent>
        </Card>
      </Box>

      <Accordion sx={{ mt: 2 }}>
        <AccordionSummary expandIcon={<ExpandMoreIcon />}>
          <Typography variant="h6">How to run this test (optional automation)</Typography>
        </AccordionSummary>
        <AccordionDetails>
          <Typography variant="body2" component="div" sx={{ "& code": { bgcolor: "action.hover", px: 0.5, borderRadius: 0.5 } }}>
            <p><b>In-app (no extra tools):</b> use the runner above. It records success, time, difficulty, note and SUS.</p>
            <p><b>Terminal, guided:</b> <code>./scripts/usability-guide.sh --opener auto</code></p>
            <p><b>Open pages with:</b> <code>--opener xdg</code> (desktop), <code>--opener playwright</code> (headed Chromium), <code>--opener selenium</code> (Chrome driver), <code>--opener cdp</code> (already-open browser via <code>cdp-tab.mjs</code>), or <code>--opener print</code>.</p>
            <p><b>Import a session:</b> <code>./scripts/usability-guided.py --import logs/guided.json</code></p>
            <p><b>Cited method:</b> <a href="/docs">Docs</a> → <code>docs/USABILITY-TESTING.md</code>; the automated layer is <code>./scripts/usability-suite.py --static-only</code>.</p>
          </Typography>
        </AccordionDetails>
      </Accordion>

      <Card sx={{ mt: 2 }}>
        <CardContent>
          <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
            <Typography variant="h6">Recent guided sessions</Typography>
            <Chip size="small" variant="outlined" label={`${sessions.length} shown`} />
          </Stack>
          {!sessions.length && <Typography variant="body2" color="text.secondary">No human-guided sessions yet. The first session becomes the baseline.</Typography>}
          {sessions.length > 0 && (
            <Table size="small">
              <TableHead>
                <TableRow><TableCell>when</TableCell><TableCell>participant</TableCell><TableCell align="right">eff</TableCell><TableCell align="right">time</TableCell><TableCell align="right">SUS</TableCell><TableCell align="right">tasks</TableCell></TableRow>
              </TableHead>
              <TableBody>
                {sessions.map((s) => (
                  <TableRow key={s.id}>
                    <TableCell>{s.ts}</TableCell>
                    <TableCell>{s.participant}</TableCell>
                    <TableCell align="right">{num(s.effectiveness)}</TableCell>
                    <TableCell align="right">{s.efficiency_s == null ? "n/a" : `${s.efficiency_s}s`}</TableCell>
                    <TableCell align="right">{num(s.satisfaction_sus)}</TableCell>
                    <TableCell align="right">{s.completed}/{s.total}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
          <Divider sx={{ my: 1 }} />
          <Typography variant="caption" color="text.secondary">
            History is stored in <code>usability_guided</code>; automated runs are separate in <code>usability_run</code>.
          </Typography>
        </CardContent>
      </Card>
    </Box>
  );
}
