import { createTheme } from "@mui/material/styles";

const font = 'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif';

export function makeTheme(mode) {
  const dark = mode === "dark";
  return createTheme({
    palette: {
      mode,
      primary: { main: "#2ea043" },
      secondary: { main: "#58a6ff" },
      error: { main: "#f85149" },
      warning: { main: "#d29922" },
      success: { main: "#3fb950" },
      background: dark
        ? { default: "#0d1117", paper: "#161b22" }
        : { default: "#f6f8fa", paper: "#ffffff" },
      divider: dark ? "#30363d" : "#d0d7de",
      text: dark
        ? { primary: "#e6edf3", secondary: "#b1bac4" }
        : { primary: "#1f2328", secondary: "#57606a" },
    },
    shape: { borderRadius: 10 },
    typography: {
      fontFamily: font,
      h4: { fontSize: "1.55rem", fontWeight: 700, letterSpacing: "-0.02em" },
      h5: { fontSize: "1.1rem", fontWeight: 700 },
      h6: { fontSize: "0.95rem", fontWeight: 700 },
      button: { textTransform: "none", fontWeight: 600 },
    },
    components: {
      MuiCssBaseline: {
        styleOverrides: {
          html: { WebkitTapHighlightColor: "transparent" },
          body: { overscrollBehaviorY: "contain" },
          "*": { boxSizing: "border-box" },
          "::selection": { background: dark ? "#1f6feb66" : "#0969da33" },
          "@media (prefers-reduced-motion: reduce)": {
            "*, *::before, *::after": {
              animationDuration: "0.01ms !important",
              animationIterationCount: "1 !important",
              transitionDuration: "0.01ms !important",
              scrollBehavior: "auto !important",
            },
          },
        },
      },
      MuiCard: {
        styleOverrides: {
          root: {
            backgroundImage: "none",
            border: `1px solid ${dark ? "#30363d" : "#d0d7de"}`,
            boxShadow: dark ? "0 1px 3px rgba(0,0,0,.35)" : "0 1px 2px rgba(0,0,0,.06)",
          },
        },
      },
      MuiPaper: { styleOverrides: { root: { backgroundImage: "none" } } },
      MuiAppBar: {
        styleOverrides: {
          root: {
            backgroundImage: "none",
            boxShadow: "none",
            borderBottom: `1px solid ${dark ? "#30363d" : "#d0d7de"}`,
          },
        },
      },
      MuiButton: {
        defaultProps: { disableElevation: true },
        styleOverrides: {
          root: { "@media (max-width:600px)": { minHeight: 44 } },
          sizeSmall: { "@media (max-width:600px)": { minHeight: 44 } },
        },
      },
      MuiIconButton: {
        styleOverrides: { root: { "@media (max-width:600px)": { minWidth: 44, minHeight: 44 } } },
      },
      MuiInputBase: {
        styleOverrides: { input: { "@media (max-width:600px)": { minHeight: 44 } } },
      },
      MuiOutlinedInput: {
        styleOverrides: { root: { "@media (max-width:600px)": { minHeight: 44 } } },
      },
      MuiChip: { styleOverrides: { root: { fontWeight: 600 } } },
      MuiTableCell: {
        styleOverrides: {
          root: { borderBottom: `1px solid ${dark ? "#21262d" : "#eaeef2"}` },
        },
      },
      MuiTooltip: { defaultProps: { arrow: true } },
      MuiBottomNavigation: {
        styleOverrides: {
          root: {
            borderTop: `1px solid ${dark ? "#30363d" : "#d0d7de"}`,
            paddingBottom: "env(safe-area-inset-bottom)",
            height: "calc(64px + env(safe-area-inset-bottom))",
          },
        },
      },
    },
  });
}
