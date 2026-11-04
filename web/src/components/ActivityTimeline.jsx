import { useEffect, useMemo, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Chip,
  IconButton,
  InputAdornment,
  Paper,
  Skeleton,
  Stack,
  TextField,
  Tooltip,
  Typography,
  useTheme,
} from "@mui/material";
import CheckIcon from "@mui/icons-material/Check";
import ContentCopyIcon from "@mui/icons-material/ContentCopy";
import ExpandLessIcon from "@mui/icons-material/ExpandLess";
import ExpandMoreIcon from "@mui/icons-material/ExpandMore";
import SearchIcon from "@mui/icons-material/Search";
import {
  activityColor,
  activityDetail,
  activityStatus,
  activityTiming,
  activityType,
  copyText,
  fmtDur,
  matchesFilter,
  timeStr,
} from "../lib.js";

const FILTERS = [
  ["all", "All"],
  ["tools", "Tools"],
  ["text", "Text"],
  ["reasoning", "Reasoning"],
  ["errors", "Errors"],
  ["steps", "Steps"],
];

function CopyButton({ text, label = "Copy", json = false }) {
  const [done, setDone] = useState(false);
  return (
    <Tooltip title={done ? "Copied" : label}>
      <IconButton
        size="small"
        aria-label={done ? "Copied" : label}
        onClick={() => {
          copyText(text, () => {
            setDone(true);
            setTimeout(() => setDone(false), 1200);
          });
        }}
      >
        {done ? <CheckIcon fontSize="small" /> : <ContentCopyIcon fontSize="small" />}
      </IconButton>
    </Tooltip>
  );
}

function ActivityRow({ x, timing, t0, t1, now, maxMs, isMobile }) {
  const theme = useTheme();
  const [open, setOpen] = useState(false);
  const detail = activityDetail(x);
  const label = activityType(x);
  const status = activityStatus(x);
  const color = activityColor(x);
  const main = color === "default" ? theme.palette.text.disabled : theme.palette[color].main;
  const startPct = Math.max(0, Math.min(100, ((timing.start - t0) / (t1 - t0)) * 100));
  const nowPct = Math.max(0, Math.min(100, ((now - t0) / (t1 - t0)) * 100));
  const width = Math.max(2, Math.sqrt(timing.ms / maxMs) * 100);
  const canMore = detail.length > 160 || detail.includes("\n");

  return (
    <Paper
      variant="outlined"
      sx={{
        p: 1.25,
        mb: 1,
        display: "grid",
        gridTemplateColumns: isMobile
          ? "minmax(0,1fr) auto"
          : "90px 116px 84px 110px 64px minmax(0,1fr) 96px",
        gridTemplateAreas: isMobile
          ? '"time actions" "type type" "detail detail" "duration duration"'
          : undefined,
        columnGap: 1,
        rowGap: 0.5,
        alignItems: "start",
      }}
    >
      <Typography
        variant="caption"
        sx={{ gridArea: isMobile ? "time" : undefined, fontFamily: "ui-monospace, monospace", fontVariantNumeric: "tabular-nums" }}
      >
        {timeStr(x.ts)}
      </Typography>

      <Box sx={{ display: isMobile ? "none" : "block", position: "relative", height: 20, bgcolor: "action.hover", borderRadius: 1 }}>
        <Box
          sx={{
            position: "absolute",
            left: `${startPct}%`,
            top: 6,
            width: 8,
            height: 8,
            borderRadius: "50%",
            bgcolor: main,
            transform: "translateX(-50%)",
          }}
        />
        <Box sx={{ position: "absolute", left: `${nowPct}%`, top: 0, bottom: 0, borderLeft: `1px dashed ${theme.palette.error.main}` }} />
      </Box>

      <Box sx={{ display: isMobile ? "none" : "block", alignSelf: "center", height: 8, bgcolor: "action.hover", borderRadius: 999, overflow: "hidden" }}>
        <Box sx={{ width: `${width}%`, height: "100%", bgcolor: main, borderRadius: 999 }} />
      </Box>

      <Box sx={{ gridArea: isMobile ? "type" : undefined, minWidth: 0 }}>
        <Chip size="small" label={label} color={color === "default" ? "default" : color} variant={color === "default" ? "outlined" : "filled"} />
        {status && (
          <Typography component="span" variant="caption" color="text.secondary" sx={{ ml: 1 }}>
            {status}
          </Typography>
        )}
      </Box>

      <Typography
        variant="caption"
        color="text.secondary"
        sx={{ gridArea: isMobile ? "duration" : undefined, alignSelf: "center", whiteSpace: "nowrap" }}
      >
        {timing.running ? "running" : fmtDur(timing.ms)}
      </Typography>

      <Box sx={{ gridArea: isMobile ? "detail" : undefined, minWidth: 0 }}>
        <Typography
          component="div"
          title={detail}
          sx={{
            fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
            fontSize: "0.76rem",
            lineHeight: 1.45,
            whiteSpace: "pre-wrap",
            overflowWrap: "anywhere",
            display: "-webkit-box",
            WebkitBoxOrient: "vertical",
            WebkitLineClamp: open ? "unset" : 3,
            overflow: open ? "visible" : "hidden",
            color: detail ? "text.primary" : "text.secondary",
          }}
        >
          {detail || "(no detail)"}
        </Typography>
      </Box>

      <Stack
        direction="row"
        spacing={0}
        sx={{ gridArea: isMobile ? "actions" : undefined, justifyContent: "flex-end" }}
      >
        {canMore && (
          <Tooltip title={open ? "Collapse" : "Expand"}>
            <IconButton size="small" aria-label={open ? "Collapse detail" : "Expand detail"} onClick={() => setOpen((v) => !v)}>
              {open ? <ExpandLessIcon fontSize="small" /> : <ExpandMoreIcon fontSize="small" />}
            </IconButton>
          </Tooltip>
        )}
        <CopyButton text={detail} label="Copy detail" />
      </Stack>
    </Paper>
  );
}

export default function ActivityTimeline({ activity, shed }) {
  const [filter, setFilter] = useState("all");
  const [query, setQuery] = useState("");
  const [showAll, setShowAll] = useState(false);
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  const all = activity || [];
  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    return all.filter((x) => {
      if (!matchesFilter(x, filter)) return false;
      if (!q) return true;
      return (
        activityDetail(x).toLowerCase().includes(q) ||
        activityType(x).toLowerCase().includes(q) ||
        String(x.status || "").toLowerCase().includes(q)
      );
    });
  }, [all, filter, query]);

  const rows = showAll ? filtered : filtered.slice(0, 30);
  const timings = useMemo(() => rows.map((x) => activityTiming(x, now)), [rows, now]);
  const maxMs = Math.max(150, ...timings.map((t) => t.ms));
  const t1 = Math.max(now, ...timings.map((t) => t.end)) + 60000;
  const t0 = Math.min(now, ...timings.map((t) => t.start));
  const isMobile = useMediaQuerySmall();

  if (activity == null) {
    return (
      <Box>
        <Skeleton variant="rounded" height={56} sx={{ mb: 1 }} />
        {[0, 1, 2, 3].map((i) => (
          <Skeleton key={i} variant="rounded" height={86} sx={{ mb: 1 }} />
        ))}
      </Box>
    );
  }

  return (
    <Box>
      <Paper variant="outlined" sx={{ p: 1.5, mb: 2 }}>
        <Stack direction={{ xs: "column", sm: "row" }} spacing={1} alignItems={{ xs: "stretch", sm: "center" }} justifyContent="space-between">
          <Box>
            <Typography variant="h5">Activity timeline</Typography>
            <Typography variant="caption" color="text.secondary">
              {rows.length} of {all.length} parts{filtered.length !== all.length ? ` · ${filtered.length} match` : ""} · newest first
            </Typography>
          </Box>
          <Stack direction="row" spacing={1} alignItems="center">
            {shed && <Chip size="small" color="warning" label="activity paused" />}
            <Chip size="small" label={showAll ? "all" : "last 30"} variant="outlined" />
            <Button size="small" variant="outlined" onClick={() => setShowAll((v) => !v)}>
              {showAll ? "Show 30" : "Show all"}
            </Button>
          </Stack>
        </Stack>

        <Box sx={{ display: "flex", flexWrap: "wrap", gap: 0.75, mt: 1.5, maxWidth: "100%", minWidth: 0 }}>
          {FILTERS.map(([id, label]) => (
            <Chip
              key={id}
              size="small"
              label={label}
              clickable
              color={filter === id ? "primary" : "default"}
              variant={filter === id ? "filled" : "outlined"}
              onClick={() => setFilter(id)}
            />
          ))}
        </Box>

        <TextField
          size="small"
          fullWidth
          placeholder="Filter commands and text…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          sx={{ mt: 1.5 }}
          slotProps={{
            input: {
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" />
                </InputAdornment>
              ),
            },
          }}
        />
      </Paper>

      {rows.length === 0 ? (
        <Alert severity="info">No activity matches this filter.</Alert>
      ) : (
        rows.map((x) => {
          const timing = activityTiming(x, now);
          return (
            <ActivityRow
              key={`${x.ts}-${x.type}-${x.tool || ""}`}
              x={x}
              timing={timing}
              t0={t0}
              t1={t1}
              now={now}
              maxMs={maxMs}
              isMobile={isMobile}
            />
          );
        })
      )}
    </Box>
  );
}

function useMediaQuerySmall() {
  const [small, setSmall] = useState(() => (typeof window !== "undefined" ? window.matchMedia("(max-width:899.95px)").matches : false));
  useEffect(() => {
    const mq = window.matchMedia("(max-width:899.95px)");
    const fn = (e) => setSmall(e.matches);
    mq.addEventListener ? mq.addEventListener("change", fn) : mq.addListener(fn);
    return () => (mq.removeEventListener ? mq.removeEventListener("change", fn) : mq.removeListener(fn));
  }, []);
  return small;
}
