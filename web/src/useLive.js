import { useEffect, useState } from "react";
import { fetchJSON } from "./lib.js";

const initial = {
  cost: null,
  activity: null,
  todos: [],
  shed: false,
  connected: false,
  polling: false,
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
        polling: false,
        last: Date.now(),
        error: null,
      }));
    };

    let poll = null;
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
          polling: true,
          last: Date.now(),
        }));
      } catch {
      }
    };
    const startPoll = () => {
      if (poll) return;
      poll = setInterval(fallback, 15000);
      fallback();
    };
    const stopPoll = () => {
      if (!poll) return;
      clearInterval(poll);
      poll = null;
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
        es.onopen = () => {
          stopPoll();
          setState((s) => ({ ...s, connected: true, error: null }));
        };
        es.onerror = () => {
          setState((s) => ({ ...s, connected: false, error: "stream disconnected" }));
          startPoll();
        };
      } catch {
        es = null;
      }
    }

    fallback();
    if (!es) startPoll();

    return () => {
      closed = true;
      if (es) es.close();
      stopPoll();
    };
  }, []);

  return state;
}

export function useRemote(path, interval = 60000) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);

  useEffect(() => {
    let closed = false;
    let timer = null;
    let load;
    const schedule = (ms) => {
      if (!closed) timer = setTimeout(load, ms);
    };
    load = async () => {
      try {
        const next = await fetchJSON(path);
        if (closed) return;
        setData(next);
        setError(null);
        schedule(interval);
      } catch (e) {
        if (closed) return;
        setError(e.message || "request failed");
        schedule(Math.min(interval, 5000));
      }
    };
    load();
    return () => {
      closed = true;
      if (timer) clearTimeout(timer);
    };
  }, [path, interval]);

  return { data, error };
}
