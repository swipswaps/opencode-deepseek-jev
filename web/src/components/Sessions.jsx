import { useMemo, useState } from "react";
import {
  Alert,
  Box,
  Card,
  Chip,
  IconButton,
  InputAdornment,
  MenuItem,
  Skeleton,
  Stack,
  Table,
  TableBody,
  TableCell,
  TableContainer,
  TableHead,
  TableRow,
  TextField,
  Tooltip,
  Typography,
} from "@mui/material";
import OpenInNewIcon from "@mui/icons-material/OpenInNew";
import SearchIcon from "@mui/icons-material/Search";
import { IS_DEMO } from "../lib.js";
import {
  dateStr,
  fmtCompact,
  fmtDur,
  fmtUsd,
  parseModel,
  sessionDuration,
  sessionHref,
} from "../lib.js";

export default function Sessions({ sessions, error, isMobile }) {
  const [query, setQuery] = useState("");
  const [sort, setSort] = useState("recent");
  const rows = useMemo(() => {
    const q = query.trim().toLowerCase();
    return (Array.isArray(sessions) ? sessions : [])
      .filter((s) => {
        if (!q) return true;
        return [s.title, s.id, s.directory, s.agent, s.model].join(" ").toLowerCase().includes(q);
      })
      .slice()
      .sort((a, b) => {
        if (sort === "cost") return (Number(b.cost) || 0) - (Number(a.cost) || 0);
        if (sort === "tokens") return ((Number(b.tokens_input) || 0) + (Number(b.tokens_output) || 0)) - ((Number(a.tokens_input) || 0) + (Number(a.tokens_output) || 0));
        if (sort === "duration") return sessionDuration(b) - sessionDuration(a);
        return Number(b.time_updated) - Number(a.time_updated);
      });
  }, [sessions, query, sort]);
  const totalCost = rows.reduce((sum, s) => sum + (Number(s.cost) || 0), 0);

  return (
    <Box>
      <Stack direction={{ xs: "column", sm: "row" }} justifyContent="space-between" alignItems={{ xs: "stretch", sm: "center" }} spacing={1} sx={{ mb: 2 }}>
        <Box>
          <Typography variant="h4">Sessions</Typography>
          <Typography variant="body2" color="text.secondary">
            {rows.length} sessions · {fmtUsd(totalCost)} · cost, tokens, model, and last update
          </Typography>
        </Box>
        <Stack direction={{ xs: "column", sm: "row" }} spacing={1}>
          <TextField
            select
            size="small"
            label="Sort"
            value={sort}
            onChange={(e) => setSort(e.target.value)}
            sx={{ minWidth: 140 }}
          >
            <MenuItem value="recent">Recent</MenuItem>
            <MenuItem value="cost">Cost</MenuItem>
            <MenuItem value="tokens">Tokens</MenuItem>
            <MenuItem value="duration">Duration</MenuItem>
          </TextField>
          <TextField
            size="small"
            placeholder="Search title, model, directory…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            sx={{ minWidth: { sm: 300 } }}
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
        </Stack>
      </Stack>

      {error && <Alert severity="warning" sx={{ mb: 1 }}>{error}</Alert>}
      {!sessions && !error && <Skeleton variant="rounded" height={320} />}

      {sessions && isMobile && (
        <Stack spacing={1}>
          {rows.map((s) => (
            <Card key={s.id} sx={{ p: 1.5 }}>
              <Stack direction="row" spacing={1} justifyContent="space-between" alignItems="flex-start">
                <Box sx={{ minWidth: 0 }}>
                  <Typography variant="body2" sx={{ fontWeight: 700 }} noWrap>
                    {s.title || s.id}
                  </Typography>
                  <Typography variant="caption" color="text.secondary" component="div" noWrap>
                    {parseModel(s.model)} · {s.agent || "?"}
                  </Typography>
                </Box>
                {!IS_DEMO && (
                  <IconButton size="small" component="a" href={sessionHref(s.id)} target="_blank" rel="noopener" aria-label="Open session">
                    <OpenInNewIcon fontSize="small" />
                  </IconButton>
                )}
              </Stack>
              <Stack direction="row" spacing={1} useFlexGap flexWrap="wrap" sx={{ mt: 1 }}>
                <Chip size="small" label={fmtUsd(s.cost)} color={Number(s.cost) >= 0.1 ? "error" : "default"} variant={Number(s.cost) >= 0.1 ? "filled" : "outlined"} />
                <Chip size="small" label={`${fmtCompact(s.tokens_input)} in`} variant="outlined" />
                <Chip size="small" label={`${fmtCompact(s.tokens_output)} out`} variant="outlined" />
                <Chip size="small" label={fmtDur(sessionDuration(s))} variant="outlined" />
              </Stack>
              <Typography variant="caption" color="text.secondary" component="div" sx={{ mt: 1 }} noWrap>
                {s.directory} · {dateStr(s.time_updated)}
              </Typography>
            </Card>
          ))}
        </Stack>
      )}

      {sessions && !isMobile && (
        <TableContainer component={Card}>
          <Table size="small" aria-label="Sessions">
            <TableHead>
              <TableRow>
                <TableCell>Session</TableCell>
                <TableCell>Model</TableCell>
                <TableCell>Updated</TableCell>
                <TableCell align="right">Duration</TableCell>
                <TableCell align="right">Tokens</TableCell>
                <TableCell align="right">Cost</TableCell>
                <TableCell align="right">Open</TableCell>
              </TableRow>
            </TableHead>
            <TableBody>
              {rows.map((s) => (
                <TableRow key={s.id} hover>
                  <TableCell sx={{ maxWidth: 380 }}>
                    <Typography variant="body2" noWrap sx={{ fontWeight: 600 }}>
                      {s.title || s.id}
                    </Typography>
                    <Typography variant="caption" color="text.secondary" component="div" noWrap>
                      {s.directory}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    <Typography variant="caption">{parseModel(s.model)}</Typography>
                    <Typography variant="caption" color="text.secondary" component="div">
                      {s.agent || "?"}
                    </Typography>
                  </TableCell>
                  <TableCell>
                    <Typography variant="caption">{dateStr(s.time_updated)}</Typography>
                  </TableCell>
                  <TableCell align="right">
                    <Typography variant="caption">{fmtDur(sessionDuration(s))}</Typography>
                  </TableCell>
                  <TableCell align="right">
                    <Typography variant="caption">
                      {fmtCompact(s.tokens_input)} / {fmtCompact(s.tokens_output)}
                    </Typography>
                  </TableCell>
                  <TableCell align="right">
                    <Typography variant="body2" color={Number(s.cost) >= 0.1 ? "error.main" : "text.primary"}>
                      {fmtUsd(s.cost)}
                    </Typography>
                  </TableCell>
                  <TableCell align="right">
                    {IS_DEMO ? (
                      <Typography variant="caption" color="text.secondary">demo</Typography>
                    ) : (
                      <Tooltip title="Open session">
                        <IconButton size="small" component="a" href={sessionHref(s.id)} target="_blank" rel="noopener" aria-label="Open session">
                          <OpenInNewIcon fontSize="small" />
                        </IconButton>
                      </Tooltip>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </TableContainer>
      )}
    </Box>
  );
}
