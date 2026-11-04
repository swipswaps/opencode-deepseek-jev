import { useMemo } from "react";
import {
  Alert,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  Divider,
  LinearProgress,
  Skeleton,
  Stack,
  Tooltip,
  Typography,
} from "@mui/material";
import ArrowForwardIcon from "@mui/icons-material/ArrowForward";
import {
  dateStr,
  fmtCompact,
  fmtDur,
  fmtUsd,
  parseModel,
  sessionHref,
  sessionDuration,
} from "../lib.js";

function Kpi({ label, value, hint, color = "text.primary" }) {
  return (
    <Card>
      <CardContent sx={{ p: 2, "&:last-child": { pb: 2 } }}>
        <Typography variant="overline" color="text.secondary" sx={{ letterSpacing: ".08em" }}>
          {label}
        </Typography>
        <Typography variant="h5" sx={{ color, lineHeight: 1.2 }} noWrap>
          {value}
        </Typography>
        {hint && (
          <Typography variant="caption" color="text.secondary">
            {hint}
          </Typography>
        )}
      </CardContent>
    </Card>
  );
}

export default function Overview({ cost, health, healthError, sessions, onNavigate }) {
  const totals = cost?.totals || {};
  const allSessions = sessions && sessions.length ? sessions : cost?.sessions || [];
  const recent = allSessions.slice(0, 5);
  const findings = health?.findings || [];
  const counts = health?.counts || {};
  const active = cost?.active;

  const trend = useMemo(() => {
    const days = new Map();
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    for (let i = 13; i >= 0; i--) {
      const d = new Date(today);
      d.setDate(d.getDate() - i);
      days.set(d.toDateString(), {
        key: d.toDateString(),
        label: d.toLocaleDateString(undefined, { month: "short", day: "numeric" }),
        cost: 0,
        n: 0,
      });
    }
    for (const s of allSessions) {
      const t = Number(s.time_updated || s.time_created);
      if (!t) continue;
      const d = new Date(t);
      d.setHours(0, 0, 0, 0);
      const row = days.get(d.toDateString());
      if (!row) continue;
      row.cost += Number(s.cost) || 0;
      row.n += 1;
    }
    return [...days.values()];
  }, [allSessions]);
  const trendTotal = trend.reduce((sum, d) => sum + d.cost, 0);
  const trendMax = Math.max(0.01, ...trend.map((d) => d.cost));

  return (
    <Box>
      <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "flex-start", sm: "center" }} spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h4">Overview</Typography>
          <Typography variant="body2" color="text.secondary">
            Cost, activity, sessions, and health from the local OpenCode store.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Chip size="small" color={active ? "success" : "default"} label={active ? "session active" : "idle"} />
          <Chip size="small" variant="outlined" label={cost?.cached ? "cached" : "live"} />
        </Stack>
      </Stack>

      <Box sx={{ display: "grid", gridTemplateColumns: { xs: "repeat(2,minmax(0,1fr))", md: "repeat(3,minmax(0,1fr))", xl: "repeat(6,minmax(0,1fr))" }, gap: 1.5 }}>
        <Kpi label="Cost" value={fmtUsd(totals.c)} hint={`${fmtCompact(totals.n)} sessions`} color="primary.main" />
        <Kpi label="Input tokens" value={fmtCompact(totals.i)} hint="context sent" />
        <Kpi label="Output tokens" value={fmtCompact(totals.o)} hint="generated" />
        <Kpi label="Reasoning" value={fmtCompact(totals.r)} hint="chain-of-thought" />
        <Kpi label="Cache read" value={fmtCompact(totals.cr)} hint="prompt cache" color="secondary.main" />
        <Kpi label="Health findings" value={health ? String(findings.length) : "…"} hint={health ? `${counts.running_tools || 0} running tools` : "loading"} color={findings.length ? "warning.main" : "success.main"} />
      </Box>

      <Card sx={{ mt: 1.5 }}>
        <CardContent sx={{ p: 2, "&:last-child": { pb: 2 } }}>
          <Stack direction="row" justifyContent="space-between" alignItems="center">
            <Box>
              <Typography variant="h6">Cost · last 14 days</Typography>
              <Typography variant="caption" color="text.secondary">
                Sum of session cost by local day
              </Typography>
            </Box>
            <Chip size="small" color="primary" label={fmtUsd(trendTotal)} />
          </Stack>
          <Box sx={{ display: "flex", alignItems: "flex-end", gap: { xs: 0.5, sm: 1 }, height: { xs: 78, sm: 110 }, mt: 1.5 }} role="img" aria-label="Cost by day for the last 14 days">
            {trend.map((d) => (
              <Tooltip key={d.key} title={`${d.label}: ${fmtUsd(d.cost)} · ${d.n} session${d.n === 1 ? "" : "s"}`}>
                <Box
                  sx={{
                    flex: 1,
                    minWidth: 4,
                    height: `${d.cost ? Math.max(4, (d.cost / trendMax) * 100) : 2}%`,
                    bgcolor: d.cost ? "primary.main" : "action.hover",
                    borderRadius: "4px 4px 0 0",
                  }}
                />
              </Tooltip>
            ))}
          </Box>
          <Typography variant="caption" color="text.secondary" component="div" sx={{ mt: 0.5 }}>
            {trend[0]?.label} – {trend[trend.length - 1]?.label}
          </Typography>
        </CardContent>
      </Card>

      <Box sx={{ display: "grid", gridTemplateColumns: { xs: "1fr", lg: "1.25fr .75fr" }, gap: 2, mt: 2 }}>
        <Card>
          <CardContent sx={{ p: 2 }}>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
              <Typography variant="h6">Recent sessions</Typography>
              <Button size="small" endIcon={<ArrowForwardIcon />} onClick={() => onNavigate("sessions")}>
                All sessions
              </Button>
            </Stack>
            {!recent.length && <Skeleton variant="rounded" height={180} />}
            {recent.map((s, i) => (
              <Box key={s.id || i}>
                {i > 0 && <Divider sx={{ my: 1 }} />}
                <Stack direction="row" spacing={1} alignItems="flex-start" justifyContent="space-between">
                  <Box sx={{ minWidth: 0 }}>
                    <Typography variant="body2" noWrap sx={{ fontWeight: 600 }}>
                      {s.title || s.id}
                    </Typography>
                    <Typography variant="caption" color="text.secondary" noWrap component="div">
                      {parseModel(s.model)} · {fmtCompact(s.tokens_input)} in · {fmtCompact(s.tokens_output)} out · {dateStr(s.time_updated)}
                    </Typography>
                  </Box>
                  <Stack alignItems="flex-end" sx={{ flexShrink: 0 }}>
                    <Typography variant="body2" color={Number(s.cost) >= 0.1 ? "error.main" : "text.primary"}>
                      {fmtUsd(s.cost)}
                    </Typography>
                    <Typography variant="caption" color="text.secondary">
                      {sessionDuration(s) ? fmtDur(sessionDuration(s)) : ""}
                    </Typography>
                  </Stack>
                </Stack>
              </Box>
            ))}
            {recent.length > 0 && (
              <Button
                size="small"
                startIcon={<ArrowForwardIcon />}
                sx={{ mt: 1 }}
                href={sessionHref(recent[0].id)}
                target="_blank"
                rel="noopener"
              >
                Open latest
              </Button>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardContent sx={{ p: 2 }}>
            <Stack direction="row" justifyContent="space-between" alignItems="center" sx={{ mb: 1 }}>
              <Typography variant="h6">Health</Typography>
              {health && <Chip size="small" color={findings.length ? "warning" : "success"} label={findings.length ? `${findings.length} findings` : "clean"} />}
            </Stack>
            {healthError && <Alert severity="warning" sx={{ mb: 1 }}>{healthError}</Alert>}
            {!health && !healthError && <Skeleton variant="rounded" height={140} />}
            {health && (
              <>
                <LinearProgress
                  variant="determinate"
                  value={Math.min(100, findings.length * 10)}
                  color={findings.length ? "warning" : "success"}
                  sx={{ height: 6, borderRadius: 999, mb: 1.5 }}
                />
                <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap" sx={{ mb: 1 }}>
                  <Chip size="small" variant="outlined" label={`${counts.sessions_scanned || 0} scanned`} />
                  <Chip size="small" variant="outlined" color={counts.running_tools ? "warning" : "default"} label={`${counts.running_tools || 0} running`} />
                  <Chip size="small" variant="outlined" color={counts.dead_tools ? "error" : "default"} label={`${counts.dead_tools || 0} dead`} />
                  <Chip size="small" variant="outlined" color={counts.blank_tails ? "warning" : "default"} label={`${counts.blank_tails || 0} blank`} />
                </Stack>
                {findings.slice(0, 4).map((f, i) => (
                  <Typography key={`${f.kind}-${f.session}-${i}`} variant="caption" component="div" color="text.secondary" noWrap>
                    {f.kind} · {f.tool || "?"} · {f.session}
                  </Typography>
                ))}
                {!findings.length && <Typography variant="body2" color="text.secondary">No health findings in the recent window.</Typography>}
              </>
            )}
          </CardContent>
        </Card>
      </Box>
    </Box>
  );
}
