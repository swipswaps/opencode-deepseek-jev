import { Alert, Box, Card, CardContent, Chip, Stack, Typography } from "@mui/material";
import TaskAltIcon from "@mui/icons-material/TaskAlt";
import PendingActionsIcon from "@mui/icons-material/PendingActions";
import DoNotDisturbAltIcon from "@mui/icons-material/DoNotDisturbAlt";

function statusMeta(status) {
  if (status === "completed") return { color: "success", icon: <TaskAltIcon fontSize="small" /> };
  if (status === "in_progress") return { color: "warning", icon: <PendingActionsIcon fontSize="small" /> };
  if (status === "cancelled") return { color: "default", icon: <DoNotDisturbAltIcon fontSize="small" /> };
  return { color: "default", icon: <PendingActionsIcon fontSize="small" /> };
}

export default function Todos({ todos }) {
  const list = Array.isArray(todos) ? todos : [];
  return (
    <Box>
      <Typography variant="h4" sx={{ mb: 0.5 }}>
        Todos
      </Typography>
      <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
        Current task state from the OpenCode todo store.
      </Typography>
      {!list.length && <Alert severity="info">No todos in the store.</Alert>}
      <Stack spacing={1}>
        {list.map((t, i) => {
          const meta = statusMeta(t.status);
          return (
            <Card key={`${t.session_id || "todo"}-${i}-${t.content}`}>
              <CardContent sx={{ p: 1.5, "&:last-child": { pb: 1.5 } }}>
                <Stack direction="row" spacing={1} alignItems="flex-start">
                  <Chip size="small" color={meta.color} icon={meta.icon} label={t.status || "pending"} sx={{ flexShrink: 0 }} />
                  <Box sx={{ minWidth: 0 }}>
                    <Typography variant="body2" sx={{ overflowWrap: "anywhere" }}>
                      {t.content}
                    </Typography>
                    <Typography variant="caption" color="text.secondary" component="div">
                      {t.session_id || ""} {t.priority ? `· priority ${t.priority}` : ""}
                    </Typography>
                  </Box>
                </Stack>
              </CardContent>
            </Card>
          );
        })}
      </Stack>
    </Box>
  );
}
