import { useEffect, useMemo, useState } from "react";
import {
  AppBar,
  Button,
  BottomNavigation,
  BottomNavigationAction,
  Box,
  Chip,
  CssBaseline,
  Divider,
  Drawer,
  IconButton,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Stack,
  ThemeProvider,
  Toolbar,
  Tooltip,
  Typography,
  useMediaQuery,
  useTheme,
} from "@mui/material";
import AddToHomeScreenIcon from "@mui/icons-material/AddToHomeScreen";
import DashboardIcon from "@mui/icons-material/Dashboard";
import TimelineIcon from "@mui/icons-material/Timeline";
import StorageIcon from "@mui/icons-material/Storage";
import ChecklistIcon from "@mui/icons-material/Checklist";
import FactCheckIcon from "@mui/icons-material/FactCheck";
import SettingsIcon from "@mui/icons-material/Settings";
import DarkModeIcon from "@mui/icons-material/DarkMode";
import LightModeIcon from "@mui/icons-material/LightMode";
import Overview from "./components/Overview.jsx";
import ActivityTimeline from "./components/ActivityTimeline.jsx";
import Sessions from "./components/Sessions.jsx";
import Todos from "./components/Todos.jsx";
import Usability from "./components/Usability.jsx";
import Settings from "./components/Settings.jsx";
import { makeTheme } from "./theme.js";
import { timeStr } from "./lib.js";
import { useLive, useRemote } from "./useLive.js";

const VIEWS = [
  { id: "overview", label: "Overview", icon: <DashboardIcon /> },
  { id: "activity", label: "Activity", icon: <TimelineIcon /> },
  { id: "sessions", label: "Sessions", icon: <StorageIcon /> },
  { id: "todos", label: "Todos", icon: <ChecklistIcon /> },
  { id: "usability", label: "Usability", icon: <FactCheckIcon /> },
  { id: "settings", label: "Settings", icon: <SettingsIcon /> },
];

const viewFromHash = () => {
  const id = String(window.location.hash || "").replace(/^#/, "");
  return VIEWS.some((v) => v.id === id) ? id : "overview";
};

function Shell({ mode, onToggleMode, canInstall, onInstall }) {
  const theme = useTheme();
  const isMobile = useMediaQuery(theme.breakpoints.down("md"));
  const [view, setView] = useState(viewFromHash);
  const live = useLive();
  const health = useRemote("/api/health", 60000);
  const sessions = useRemote("/api/sessions?limit=200", 60000);
  const current = VIEWS.find((v) => v.id === view) || VIEWS[0];

  useEffect(() => {
    const onHash = () => setView(viewFromHash());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  useEffect(() => {
    document.title = `opencode observability · ${current.label}`;
    window.scrollTo({ top: 0, behavior: "auto" });
  }, [view, current.label]);

  const selectView = (id) => {
    if (id === view) return;
    if (window.location.hash === `#${id}`) setView(id);
    else window.location.hash = id;
  };

  return (
    <Box sx={{ display: "flex", minHeight: "100vh", bgcolor: "background.default" }}>
      <Box
        component="a"
        href="#main"
        sx={{
          position: "fixed",
          left: -9999,
          top: 8,
          zIndex: 2000,
          px: 2,
          py: 1,
          borderRadius: 1,
          bgcolor: "primary.main",
          color: "#0d1117",
          fontWeight: 700,
          "&:focus": { left: 8 },
        }}
      >
        Skip to main content
      </Box>
      <AppBar position="fixed" color="inherit" sx={{ zIndex: theme.zIndex.drawer + 1, bgcolor: "background.paper" }}>
        <Toolbar sx={{ gap: 1, minHeight: { xs: 56, md: 64 } }}>
          <Box
            sx={{
              width: 30,
              height: 30,
              borderRadius: 1.5,
              bgcolor: "primary.main",
              display: "grid",
              placeItems: "center",
              flexShrink: 0,
            }}
          >
            <TimelineIcon sx={{ fontSize: 19, color: "#0d1117" }} />
          </Box>
          <Typography variant="h6" sx={{ letterSpacing: "-.02em", fontSize: { xs: "0.95rem", sm: "1.1rem" }, display: "block" }}>
            observability
          </Typography>
          <Chip
            size="small"
            color={live.connected ? "success" : "default"}
            label={live.connected ? "live" : "offline"}
            variant={live.connected ? "filled" : "outlined"}
          />
          {live.shed && <Chip size="small" color="warning" label="paused" />}
          <Box sx={{ flexGrow: 1 }} />
          <Typography variant="caption" color="text.secondary" sx={{ display: { xs: "none", sm: "block" } }}>
            {live.last ? `updated ${timeStr(live.last)}` : "waiting for stream"}
          </Typography>
          {canInstall && (
            <>
              <Button
                size="small"
                variant="outlined"
                startIcon={<AddToHomeScreenIcon />}
                onClick={onInstall}
                sx={{ display: { xs: "none", sm: "inline-flex" } }}
              >
                Install
              </Button>
              <Tooltip title="Install app">
                <IconButton aria-label="Install app" onClick={onInstall} sx={{ display: { xs: "inline-flex", sm: "none" } }}>
                  <AddToHomeScreenIcon />
                </IconButton>
              </Tooltip>
            </>
          )}
          <Tooltip title={mode === "dark" ? "Switch to light theme" : "Switch to dark theme"}>
            <IconButton aria-label="Toggle light or dark theme" onClick={onToggleMode}>
              {mode === "dark" ? <LightModeIcon /> : <DarkModeIcon />}
            </IconButton>
          </Tooltip>
        </Toolbar>
      </AppBar>

      <Drawer
        variant="permanent"
        sx={{
          display: { xs: "none", md: "block" },
          width: 236,
          flexShrink: 0,
          "& .MuiDrawer-paper": {
            width: 236,
            boxSizing: "border-box",
            top: 64,
            height: "calc(100% - 64px)",
            bgcolor: "background.default",
            borderRight: "1px solid",
            borderColor: "divider",
          },
        }}
      >
        <Box sx={{ p: 1.5 }}>
          <List aria-label="Views" sx={{ pt: 0 }}>
            {VIEWS.map((v) => (
              <ListItemButton
                key={v.id}
                selected={view === v.id}
                onClick={() => selectView(v.id)}
                sx={{ borderRadius: 2, mb: 0.5, minHeight: 44 }}
              >
                <ListItemIcon sx={{ minWidth: 38, color: view === v.id ? "primary.main" : "text.secondary" }}>
                  {v.icon}
                </ListItemIcon>
                <ListItemText primary={v.label} slotProps={{ primary: { sx: { fontWeight: view === v.id ? 700 : 500 } } }} />
              </ListItemButton>
            ))}
          </List>
          <Divider sx={{ my: 1.5 }} />
          <Button component="a" href="/" size="small" sx={{ mb: 1 }}>
            Classic view
          </Button>
          <Typography variant="caption" color="text.secondary" component="div">
            Local read-only · /api/stream
          </Typography>
          <Typography variant="caption" color="text.secondary" component="div">
            {live.last ? `updated ${timeStr(live.last)}` : "waiting"}
          </Typography>
        </Box>
      </Drawer>

      <Box component="main" id="main" tabIndex={-1} sx={{ flexGrow: 1, minWidth: 0, pt: { xs: "56px", md: "64px" }, pb: { xs: "80px", md: 0 }, outline: "none" }}>
        <Box sx={{ maxWidth: 1500, mx: "auto", p: { xs: 2, md: 3 } }}>
          {view === "overview" && (
            <Overview
              cost={live.cost}
              health={health.data}
              healthError={health.error}
              sessions={sessions.data}
              onNavigate={selectView}
            />
          )}
          {view === "activity" && <ActivityTimeline activity={live.activity} shed={live.shed} />}
          {view === "sessions" && <Sessions sessions={sessions.data} error={sessions.error} isMobile={isMobile} />}
          {view === "todos" && <Todos todos={live.todos} />}
          {view === "usability" && <Usability />}
          {view === "settings" && <Settings />}
        </Box>
      </Box>

      <BottomNavigation
        showLabels
        value={view}
        onChange={(e, v) => v && selectView(v)}
        sx={{
          display: { xs: "flex", md: "none" },
          position: "fixed",
          bottom: 0,
          left: 0,
          right: 0,
          zIndex: theme.zIndex.appBar,
          bgcolor: "background.paper",
        }}
      >
        {VIEWS.map((v) => (
          <BottomNavigationAction key={v.id} value={v.id} label={v.label} icon={v.icon} />
        ))}
      </BottomNavigation>
    </Box>
  );
}

export default function App() {
  const [mode, setMode] = useState(() => {
    try {
      const saved = localStorage.getItem("ocweb-theme");
      if (saved === "light" || saved === "dark") return saved;
      return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
    } catch {
      return "dark";
    }
  });
  const theme = useMemo(() => makeTheme(mode), [mode]);
  const [installEvent, setInstallEvent] = useState(null);

  useEffect(() => {
    const onPrompt = (e) => {
      e.preventDefault();
      setInstallEvent(e);
    };
    const onInstalled = () => setInstallEvent(null);
    window.addEventListener("beforeinstallprompt", onPrompt);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onPrompt);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  const install = async () => {
    if (!installEvent) return;
    try {
      installEvent.prompt();
      await installEvent.userChoice;
    } catch {
      /* prompt unavailable */
    }
    setInstallEvent(null);
  };

  useEffect(() => {
    try {
      localStorage.setItem("ocweb-theme", mode);
    } catch {
      /* private mode */
    }
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", mode === "dark" ? "#0d1117" : "#f6f8fa");
  }, [mode]);

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <Shell
        mode={mode}
        onToggleMode={() => setMode((m) => (m === "dark" ? "light" : "dark"))}
        canInstall={Boolean(installEvent)}
        onInstall={install}
      />
    </ThemeProvider>
  );
}
