import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Crosshair, Keyboard, MousePointer2, PauseCircle, Radio, Search, Waves } from 'lucide-react';
import './styles.css';

const API = import.meta.env.VITE_REWIND_API ?? 'http://127.0.0.1:4317';
const EVENT_KINDS = new Set(['click', 'typing', 'scroll', 'focus']);

function icon(kind, size = 14) {
  if (kind === 'click') return <MousePointer2 size={size} />;
  if (kind === 'typing') return <Keyboard size={size} />;
  if (kind === 'scroll') return <Waves size={size} />;
  return <Crosshair size={size} />;
}

function spanLabel(span) {
  const a = span?.attributes ?? {};
  if (!span) return '';
  if (span.kind === 'typing') return a['keyboard.typed_text'] ? `typed ${a['keyboard.typed_text']}` : 'typing';
  if (span.kind === 'click') return span.uiSummary || 'click';
  if (span.kind === 'scroll') return 'scroll';
  return span.name?.replace(/^human\./, '') || span.kind;
}

function spanTitle(span) {
  const a = span?.attributes ?? {};
  return [spanLabel(span), a['app.name'], a['window.title']].filter(Boolean).join(' | ');
}

function time(ms) {
  return ms ? new Date(ms).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '';
}

function timelineWindow(spans, selectedId) {
  const stride = Math.max(1, Math.ceil(spans.length / 220));
  return spans.filter((span, index) => span.screenshotUrl || span.id === selectedId || index % stride === 0).slice(-260);
}

function App() {
  const [spans, setSpans] = useState([]);
  const [selectedId, setSelectedId] = useState('');
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [autoFollow, setAutoFollow] = useState(true);
  const [recorder, setRecorder] = useState({ available: false, recording: false });
  const [recorderBusy, setRecorderBusy] = useState(false);
  const autoFollowRef = useRef(true);
  const selectedIdRef = useRef('');
  const shouldCenterSelectedRef = useRef(true);
  const railRef = useRef(null);
  const scrollRafRef = useRef(0);
  const scrollSettleTimerRef = useRef(0);
  const programmaticScrollRef = useRef(false);

  useEffect(() => {
    autoFollowRef.current = autoFollow;
  }, [autoFollow]);

  useEffect(() => {
    selectedIdRef.current = selectedId;
  }, [selectedId]);

  async function loadTimeline({ keepSelection = true } = {}) {
    const data = await fetch(`${API}/api/timeline?limit=2500`).then(r => r.json());
    const visible = data.filter(s => EVENT_KINDS.has(s.kind));
    setSpans(visible);
    const latest = visible.at(-1);
    const currentSelected = selectedIdRef.current;
    if (!keepSelection || autoFollowRef.current || !currentSelected || !visible.some(s => s.id === currentSelected)) {
      shouldCenterSelectedRef.current = autoFollowRef.current || !currentSelected || !visible.some(s => s.id === currentSelected);
      setSelectedId(latest?.id ?? '');
    }
  }

  async function loadRecorderStatus() {
    const status = await fetch(`${API}/api/recorder/status`).then(r => r.json());
    setRecorder(status);
  }

  useEffect(() => {
    loadTimeline({ keepSelection: false });
    loadRecorderStatus();
    const timelineTimer = setInterval(() => loadTimeline(), 1800);
    const recorderTimer = setInterval(loadRecorderStatus, 1500);
    return () => {
      clearInterval(timelineTimer);
      clearInterval(recorderTimer);
      cancelAnimationFrame(scrollRafRef.current);
      clearTimeout(scrollSettleTimerRef.current);
    };
  }, []);

  useEffect(() => {
    const id = setTimeout(async () => {
      if (!query.trim()) return setResults([]);
      const url = new URL('/api/search', API);
      url.searchParams.set('q', query);
      setResults(await fetch(url).then(r => r.json()));
    }, 160);
    return () => clearTimeout(id);
  }, [query]);

  useEffect(() => {
    if (!selectedId) return;
    if (!shouldCenterSelectedRef.current) return;
    programmaticScrollRef.current = true;
    requestAnimationFrame(() => {
      document.querySelector(`[data-span-id="${selectedId}"]`)?.scrollIntoView({
        inline: autoFollow ? 'end' : 'center',
        block: 'nearest',
        behavior: autoFollow ? 'smooth' : 'auto',
      });
      window.setTimeout(() => {
        programmaticScrollRef.current = false;
      }, autoFollow ? 520 : 120);
    });
  }, [selectedId, autoFollow]);

  const selected = spans.find(s => s.id === selectedId) ?? spans.at(-1);
  const screenshotSpan = selected?.screenshotUrl ? selected : [...spans].reverse().find(s => s.start_time_ms <= (selected?.start_time_ms ?? Infinity) && s.screenshotUrl) ?? [...spans].reverse().find(s => s.screenshotUrl);
  const screenshotSrc = screenshotSpan?.screenshotUrl ? `${API}${screenshotSpan.screenshotUrl}` : '';
  const timeline = useMemo(() => timelineWindow(spans, selected?.id), [spans, selected?.id]);

  function jumpTo(result) {
    setAutoFollow(false);
    const existing = spans.find(s => s.id === result.span_id);
    if (existing) {
      shouldCenterSelectedRef.current = true;
      setSelectedId(existing.id);
    }
    setResults([]);
    setQuery(result.title);
  }

  function choose(span) {
    setAutoFollow(false);
    shouldCenterSelectedRef.current = false;
    setSelectedId(span.id);
  }

  function selectCenteredSpan() {
    const rail = railRef.current;
    if (!rail) return;
    const railRect = rail.getBoundingClientRect();
    const centerX = railRect.left + railRect.width / 2;
    let closestId = '';
    let closestDistance = Infinity;
    rail.querySelectorAll('[data-span-id]').forEach((element) => {
      const rect = element.getBoundingClientRect();
      const distance = Math.abs(rect.left + rect.width / 2 - centerX);
      if (distance < closestDistance) {
        closestDistance = distance;
        closestId = element.dataset.spanId || '';
      }
    });
    if (closestId && closestId !== selectedIdRef.current) {
      shouldCenterSelectedRef.current = false;
      selectedIdRef.current = closestId;
      setSelectedId(closestId);
    }
  }

  function handleRailScroll() {
    if (programmaticScrollRef.current) return;
    if (autoFollowRef.current) {
      autoFollowRef.current = false;
      setAutoFollow(false);
    }
    shouldCenterSelectedRef.current = false;
    cancelAnimationFrame(scrollRafRef.current);
    scrollRafRef.current = requestAnimationFrame(selectCenteredSpan);
    clearTimeout(scrollSettleTimerRef.current);
    scrollSettleTimerRef.current = window.setTimeout(() => {
      selectCenteredSpan();
      scrollSettleTimerRef.current = window.setTimeout(selectCenteredSpan, 260);
    }, 110);
  }

  async function toggleRecorder() {
    setRecorderBusy(true);
    try {
      const command = recorder.recording ? 'stop' : 'start';
      const response = await fetch(`${API}/api/recorder/${command}`, { method: 'POST' }).then(r => r.json());
      setRecorder(response.status ?? response);
      if (command === 'start') setAutoFollow(true);
      shouldCenterSelectedRef.current = command === 'start';
      await loadTimeline({ keepSelection: command !== 'start' });
    } finally {
      setRecorderBusy(false);
    }
  }

  return <div className="rewind">
    {screenshotSrc && <img className="ambient" src={screenshotSrc} alt="" />}

    <div className="brand">Mochi<span>rewind</span></div>

    <main className="screen">
      {screenshotSrc && <img className="screen-image" src={screenshotSrc} alt="" />}
    </main>

    <form className="search-wrap" onSubmit={e => e.preventDefault()}>
      <Search size={16} />
      <input value={query} onChange={e => setQuery(e.target.value)} placeholder="Search anything you've seen, said, or heard" />
      {results.length > 0 && <div className="results">
        {results.map(r => <button key={`${r.run_id}-${r.span_id}`} onClick={() => jumpTo(r)}>
          <b>{r.title}</b><span dangerouslySetInnerHTML={{ __html: r.snippet }} />
        </button>)}
      </div>}
    </form>

    <button
      className={`record-toggle ${recorder.recording ? 'on' : ''}`}
      onClick={toggleRecorder}
      disabled={recorderBusy || !recorder.available}
      aria-pressed={recorder.recording}
      title={recorder.recording ? 'Stop recording' : recorder.available ? 'Start recording' : 'Menu recorder unavailable'}>
      {recorder.recording ? <Radio size={17} /> : <PauseCircle size={17} />}
    </button>

    <footer className="timeline">
      <div className="rail-wrap">
        <div className="center-playhead" aria-hidden="true" />
        <div className="rail" ref={railRef} onScroll={handleRailScroll}>
        {timeline.map((span) => <button
          key={span.id}
          data-span-id={span.id}
          className={`tick ${span.kind} ${span.screenshotUrl ? 'has-preview' : ''} ${span.id === selected?.id ? 'active' : ''}`}
          onClick={() => choose(span)}
          title={spanTitle(span)}>
          {span.screenshotUrl && <img className="tick-preview" src={`${API}${span.screenshotUrl}`} alt="" loading="lazy" />}
          {icon(span.kind)}
          <span>{time(span.start_time_ms)}</span>
          <b>{spanLabel(span)}</b>
          {span.screenshotUrl && <i />}
        </button>)}
        </div>
      </div>
      {selected && <button className="now" onClick={() => { setAutoFollow(true); shouldCenterSelectedRef.current = true; setSelectedId(spans.at(-1)?.id ?? selected.id); }}>
        <span>{autoFollow ? 'Now' : time(selected.start_time_ms)}</span>
      </button>}
    </footer>
  </div>;
}

createRoot(document.getElementById('root')).render(<App />);
