import { useEffect, useState } from "react";
import { fetchJSON } from "./lib.js";

const initial = {
  cost: null,
  activity: null,
  todos: [],
  shed: false,
  connected: false,
  last: null,
  error: null,
};

export function useLive() {
  const [state, setState] = useState(initial);

  useEffect(() => {
    let closed = false;
    let es = null;

    const apply = (payload) => {
      if (closed || !payload) return;
      setState((s) => ({
        ...s,
        cost: payload.cost ?? s.cost,
        activity: Array.isArray(payload.activity) ? payload.activity : s.activity,
        todos: Array.isArray(payload.todos) ? payload.todos : s.todos,
        shed: Boolean(payload.shed),
        connected: true,
        last: Date.now(),
        error: null,
      }));
    };

    const fallback = async () => {
      try {
        const [cost, activity, todos] = await Promise.all([
          fetchJSON("/api/cost").catch(() => null),
          fetchJSON("/api/activity").catch(() => null),
          fetchJSON("/api/todos").catch(() => null),
        ]);
        if (closed) return;
        setState((s) => ({
          ...s,
          cost: cost || s.cost,
          activity: Array.isArray(activity) ? activity : s.activity,
          todos: Array.isArray(todos) ? todos : s.todos,
          last: s.last || Date.now(),
        }));
      } catch {
      }
    };

    if (typeof EventSource !== "undefined") {
      try {
        es = new EventSource("/api/stream");
        const onflow = (ev) => {
          try {
            apply(JSON.parse(ev.data));
          } catch {
          }
        };
        es.addEventListener("snapshot", onflow);
        es.addEventListener("delta", onflow);
        es.onopen = () => setState((s) => ({ ...s, connected: true, error: null }));
        es.onerror = () => setState((s) => ({ ...s, connected: false, error: "stream disconnected" }));
      } catch {
        es = null;
      }
    }

    fallback();
    let poll = null;
    if (!es) {
      poll = setInterval(fallback, 15000);
    }

    return () => {
      closed = true;
      if (es) es.close();
      if (poll) clearInterval(poll);
    };
  }, []);

  return state;
}

export function useRemote(path, interval = 60000) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let closed = false;
    const load = async () => {
      try {
        const next = await fetchJSON(path);
        if (closed) return;
        setData(next);
        setError(null);
      } catch (e) {
        if (!closed) setError(e.message || "request failed");
      }
    };
    load();
    const timer = setInterval(load, interval);
    return () => {
      closed = true;
      clearInterval(timer);
    };
  }, [path, interval]);

  return { data, error };
}
