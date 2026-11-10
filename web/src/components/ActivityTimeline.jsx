import { useEffect, useMemo, useRef, useState } from "react";
import {
  Alert,
  Box,
  Button,
  Chip,
  FormControlLabel,
  IconButton,
  InputAdornment,
  Paper,
  Skeleton,
  Stack,
  Switch,
  TextField,
  Tooltip,
  Typography,
  useTheme,
} from "@mui/material";
import CheckIcon from "@mui/icons-material/Check";
import CloseIcon from "@mui/icons-material/Close";
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
  fetchJSON,
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
];

function activityFromHit(h) {
  const isTool = h.type === "tool";
  return {
    ts: h.ts,
    te: h.ts,
    type: h.type,
    tool: isTool ? (h.tool || "tool") : undefined,
    status: h.status || "",
    cmd: isTool ? (h.snippet || "") : "",
    text: isTool ? "" : (h.snippet || ""),
    session: h.session,
    sessionTitle: h.title,
    searchHit: true,
  };
}

function CopyButton({ text, label = "Copy" }) {
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
        {x.sessionTitle && (
          <Typography variant="caption" color="text.secondary" noWrap display="block" title={x.sessionTitle}>
            {x.sessionTitle}
          </Typography>
        )}
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
  const [showSteps, setShowSteps] = useState(false);
  const [now, setNow] = useState(Date.now());
  // The live `activity` prop is bounded to the 12 most recently updated
  // sessions (server-side, for latency). A search box over that window silently
  // loses older hits as new activity arrives. When a query is present we ask
  // /api/search, which scans all sessions, and render those hits in the same
  // row shape. "Show all" then expands the real hit set, not just 30 rows.
  const [remote, setRemote] = useState(null);
  const [remoteBusy, setRemoteBusy] = useState(false);
  const [remoteError, setRemoteError] = useState("");
  const searchRef = useRef(null);

  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);

  useEffect(() => {
    const onKey = (e) => {
      const tag = document.activeElement && document.activeElement.tagName;
      if (e.key === "/" && tag !== "INPUT" && tag !== "TEXTAREA") {
        e.preventDefault();
        if (searchRef.current) searchRef.current.focus();
      }
      if (e.key === "Escape" && document.activeElement === searchRef.current) {
        setQuery("");
        searchRef.current.blur();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  useEffect(() => {
    const q = query.trim();
    if (!q) {
      setRemote(null);
      setRemoteBusy(false);
      return undefined;
    }
    let cancelled = false;
    setRemoteBusy(true);
    setRemoteError("");
    const timer = setTimeout(async () => {
      let rows = [];
      let error = "";
      try {
        // The legacy LIKE search can run for several seconds on a cold worker;
        // the 12 s default was aborting and showing a false "No matches".
        const d = await fetchJSON("/api/search?q=" + encodeURIComponent(q) + "&limit=200&full=1", 45000);
        rows = ((d && d.hits) || []).map(activityFromHit);
      } catch {
        // Fast fallback: the FTS5 index answers in ~200 ms. Its snippets are
        // shorter, but a hit is better than a false negative.
        try {
          const s = await fetchJSON("/api/semantic?q=" + encodeURIComponent(q) + "&limit=200", 20000);
          rows = ((s && s.results) || []).map(activityFromHit);
        } catch {
          rows = [];
          error = "Search timed out. Retry, or use the Search card below.";
        }
      }
      if (cancelled) return;
      setRemote({ q, rows, error });
      setRemoteError(error);
      setRemoteBusy(false);
    }, 250);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [query]);

  const q = query.trim();
  const all = q
    ? (remote && remote.q === q ? remote.rows : [])
    : (activity || []);
  const filtered = useMemo(() => {
    const needle = q.toLowerCase();
    return all.filter((x) => {
      if (!matchesFilter(x, filter)) return false;
      if (!showSteps && String(x.type || "").startsWith("step")) return false;
      // Remote hits already matched server-side across all sessions; re-testing
      // the snippet would drop a hit whose match was in a field the snippet
      // does not show (e.g. the command when text is present).
      if (!needle || x.searchHit) return true;
      return (
        activityDetail(x).toLowerCase().includes(needle) ||
        activityType(x).toLowerCase().includes(needle) ||
        String(x.status || "").toLowerCase().includes(needle)
      );
    });
  }, [all, filter, q, showSteps]);
  const rows = showAll ? filtered : filtered.slice(0, 30);
  const timings = useMemo(() => rows.map((x) => activityTiming(x, now)), [rows, now]);
  const maxMs = Math.max(150, ...timings.map((t) => t.ms));
  const t1 = Math.max(now, ...timings.map((t) => t.end)) + 60000;
  const t0 = Math.min(now, ...timings.map((t) => t.start));
  const nowPct = t1 > t0 ? Math.max(0, Math.min(100, ((now - t0) / (t1 - t0)) * 100)) : 100;
  const clock = (t) => new Date(t).toLocaleTimeString(undefined, { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });
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
              {remoteBusy
                ? "searching all sessions…"
                : q
                  ? remoteError
                    ? remoteError
                    : `${rows.length} of ${filtered.length} matches across all sessions · newest first`
                  : `${rows.length} of ${filtered.length} parts${filtered.length !== all.length ? ` · ${all.length} recent` : ""} · newest first`}
            </Typography>
          </Box>
          <Stack direction="row" spacing={1} alignItems="center">
            {shed && <Chip size="small" color="warning" label="activity paused" />}
            <Chip size="small" label={showAll ? "all" : "last 30"} variant="outlined" />
            <Button size="small" variant="outlined" onClick={() => setShowAll((v) => !v)}>
              {showAll ? "Show 30" : "Show all"}
            </Button>
            <CopyButton text={JSON.stringify(rows, null, 2)} label="Copy visible JSON" />
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
          <FormControlLabel
            control={<Switch size="small" checked={showSteps} onChange={(e) => setShowSteps(e.target.checked)} inputProps={{ "aria-label": "Show step rows" }} />}
            label={<Typography variant="caption">Steps</Typography>}
            sx={{ ml: 0, mr: 0, minHeight: 32 }}
          />
        </Box>

        <TextField
          size="small"
          fullWidth
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          inputRef={searchRef}
          aria-keyshortcuts="/"
          placeholder="Filter commands and text…  ( / )"
          sx={{ mt: 1.5 }}
          slotProps={{
            input: {
              startAdornment: (
                <InputAdornment position="start">
                  <SearchIcon fontSize="small" />
                </InputAdornment>
              ),
              endAdornment: query ? (
                <InputAdornment position="end">
                  <IconButton size="small" aria-label="Clear activity filter" onClick={() => setQuery("")}>
                    <CloseIcon fontSize="small" />
                  </IconButton>
                </InputAdornment>
              ) : null,
            },
          }}
        />
      </Paper>

      {!isMobile && rows.length > 0 && (
        <Box
          sx={{
            display: "grid",
            gridTemplateColumns: "90px 116px 84px 110px 64px minmax(0,1fr) 96px",
            columnGap: 1,
            alignItems: "center",
            px: 1.25,
            pb: 0.5,
            color: "text.secondary",
          }}
          aria-hidden="true"
        >
          <Typography variant="caption">
            time <Box component="span" sx={{ color: "error.main", fontWeight: 700 }}>· now</Box>
          </Typography>
          <Box sx={{ position: "relative", height: 20 }}>
            <Typography variant="caption" sx={{ position: "absolute", left: 0, top: 0, whiteSpace: "nowrap" }}>{clock(t0)}</Typography>
            <Typography variant="caption" sx={{ position: "absolute", right: 0, top: 0, whiteSpace: "nowrap" }}>{clock(t1)}</Typography>
            <Box sx={{ position: "absolute", left: `${nowPct}%`, top: 0, bottom: 0, borderLeft: "1px dashed", borderColor: "error.main", opacity: 0.8 }} />
          </Box>
          <Typography variant="caption">rel. dur</Typography>
          <Typography variant="caption">type</Typography>
          <Typography variant="caption">dur</Typography>
          <Typography variant="caption">detail</Typography>
          <Typography variant="caption" />
        </Box>
      )}

      {rows.length === 0 ? (
        <Alert severity={remoteError ? "warning" : "info"}>
          {remoteBusy
            ? "Searching all sessions…"
            : remoteError
              ? remoteError
              : q
                ? `No matches for “${q}” across all sessions.`
                : "No activity matches this filter."}
        </Alert>
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
