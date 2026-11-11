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
  Typography,
} from "@mui/material";
import OpenInNewIcon from "@mui/icons-material/OpenInNew";
import FactCheckIcon from "@mui/icons-material/FactCheck";
import { useRemote } from "../useLive.js";

function num(v) {
  return v == null || Number.isNaN(Number(v)) ? "n/a" : String(v);
}

export default function Usability() {
  const auto = useRemote("/api/usability", 30000);
  const history = useRemote("/api/usability/guided?limit=10", 30000);
  const run = auto.data && auto.data.verdict ? auto.data : null;
  const sessions = history.data?.sessions || [];

  return (
    <Box>
      <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "flex-start", sm: "center" }} spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography component="h1" variant="h4">Usability</Typography>
          <Typography variant="body2" color="text.secondary">
            Two separate signals: an automated screen (machine evidence) and a guided human test (operator + participant).
          </Typography>
        </Box>
        <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
          <Chip size="small" color={run ? (run.verdict === "PASS" ? "success" : run.verdict === "FAIL" ? "error" : "default") : "default"} label={`auto ${run?.verdict || "n/a"}`} />
          <Chip size="small" variant="outlined" label={`SUS ${num(run?.satisfaction_sus)}`} />
        </Stack>
      </Stack>

      <Alert severity="info" icon={<FactCheckIcon />} sx={{ mb: 2 }}>
        <Typography variant="body2" sx={{ mb: 1 }}>
          <b>This page is the summary.</b> Run the guided test on the dedicated page: it walks one participant through
          the task script, times each goal, records Done / Failed / Skip, then captures the 10-item SUS questionnaire.
        </Typography>
        <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
          <Button variant="contained" endIcon={<OpenInNewIcon />} component="a" href="/usability">
            Run the guided test
          </Button>
          <Button variant="outlined" endIcon={<OpenInNewIcon />} component="a" href="/docs">
            Method and citations
          </Button>
        </Stack>
      </Alert>

      <Box sx={{ display: "grid", gridTemplateColumns: { xs: "1fr", lg: "1.1fr .9fr" }, gap: 2 }}>
        <Card>
          <CardContent>
            <Typography variant="h6" sx={{ mb: 1 }}>Automated evidence</Typography>
            {!run && (
              <Alert severity="info">
                No automated run yet. Run <code>./scripts/usability-suite.py --static-only</code> on the host.
              </Alert>
            )}
            {run && (
              <Stack spacing={1.25}>
                <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap">
                  <Chip size="small" label={`mode ${run.mode || "?"}`} />
                  <Chip size="small" color={run.fail_count ? "warning" : "success"} label={`${run.fail_count || 0} failures`} />
                  <Chip size="small" variant="outlined" label={`${run.skip_count || 0} skips`} />
                  <Chip size="small" variant="outlined" label={`effectiveness ${num(run.effectiveness)}`} />
                  <Chip size="small" variant="outlined" label={`time ${run.efficiency_s == null ? "n/a" : `${run.efficiency_s}s`}`} />
                </Stack>
                <TableContainer>
                <Table size="small">
                  <TableHead>
                    <TableRow>
                      <TableCell>axis</TableCell>
                      <TableCell align="right">pass</TableCell>
                      <TableCell align="right">fail</TableCell>
                      <TableCell align="right">skip</TableCell>
                      <TableCell align="right">score</TableCell>
                    </TableRow>
                  </TableHead>
                  <TableBody>
                    {Object.entries(run.axes || {}).map(([k, v]) => (
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
                </TableContainer>
                {(run.failures || []).slice(0, 5).map((f) => (
                  <Typography key={`${f.axis}-${f.metric}`} variant="caption" color="error" component="div">
                    FAIL {f.axis}/{f.metric}: {f.detail}
                  </Typography>
                ))}
                {run.caveat && <Typography variant="caption" color="text.secondary">{run.caveat}</Typography>}
              </Stack>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardContent>
            <Typography variant="h6" sx={{ mb: 1 }}>How the guided test works</Typography>
            <Typography variant="body2" component="ol" sx={{ pl: 2.5, m: 0, "& li": { mb: 0.75 } }}>
              <li>Open the guided runner on <code>/usability</code>.</li>
              <li>Label the participant (a pseudonym is fine; no personal data).</li>
              <li>Read each goal; the participant uses the app; record Done / Failed / Skip and note any friction.</li>
              <li>Finish with the 10-item SUS questionnaire and submit. The session becomes the baseline.</li>
            </Typography>
            <Divider sx={{ my: 1.25 }} />
            <Typography variant="caption" color="text.secondary" component="div">
              Terminal alternative: <code>./scripts/usability-guide.sh --opener xdg</code><br />
              Import a session: <code>./scripts/usability-guided.py --import logs/guided.json</code>
            </Typography>
          </CardContent>
        </Card>
      </Box>

      <Card sx={{ mt: 2 }}>
        <CardContent>
          <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
            <Typography variant="h6">Recent guided sessions</Typography>
            <Chip size="small" variant="outlined" label={`${sessions.length} shown`} />
          </Stack>
          {!sessions.length && (
            <Typography variant="body2" color="text.secondary">
              No human-guided sessions yet. The first session becomes the baseline.
            </Typography>
          )}
          {sessions.length > 0 && (
            <TableContainer>
            <Table size="small">
              <TableHead>
                <TableRow>
                  <TableCell>when</TableCell>
                  <TableCell>participant</TableCell>
                  <TableCell align="right">eff</TableCell>
                  <TableCell align="right">time</TableCell>
                  <TableCell align="right">SUS</TableCell>
                  <TableCell align="right">tasks</TableCell>
                </TableRow>
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
            </TableContainer>
          )}
          <Divider sx={{ my: 1 }} />
          <Typography variant="caption" color="text.secondary">
            Guided history is stored in <code>usability_guided</code>; automated runs are separate in <code>usability_run</code>.
          </Typography>
        </CardContent>
      </Card>
    </Box>
  );
}
