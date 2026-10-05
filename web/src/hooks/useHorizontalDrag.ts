import { useCallback, useEffect, useRef, useState } from 'react';

/**
 * Touch-safe horizontal drag-to-adjust gesture for level pills.
 *
 * The element using these handlers must set `touchAction: 'pan-y'` so the
 * browser owns vertical scrolling. A gesture is classified once it has moved
 * CLASSIFY_PX in any direction:
 *  - horizontal (|dx| >= CLASSIFY_PX and |dx| > 2*|dy|) -> adjust the level;
 *    only then is the pointer captured.
 *  - anything else -> abandoned: no level change and no tap on release.
 * A release with no significant movement is a tap. pointercancel (e.g. the
 * browser taking over a vertical scroll) resets without sending anything.
 */
const CLASSIFY_PX = 10;

type Phase = 'idle' | 'pending' | 'dragging' | 'abandoned';

interface Options {
  min: number; // lowest level a drag can produce (1 for lights, 0 for shades)
  /** Called (debounced) while dragging. */
  onAdjust: (level: number) => void;
  /** Called once on release after a horizontal drag. */
  onCommit: (level: number) => void;
  /** Called on release when the pointer never moved significantly. */
  onTap?: () => void;
  /** Return true to ignore a pointerdown (e.g. it landed on an inner button). */
  ignore?: (e: React.PointerEvent) => boolean;
}

export function useHorizontalDrag<T extends HTMLElement>(level: number, opts: Options) {
  const ref = useRef<T>(null);
  const [localLevel, setLocalLevel] = useState(level);
  const [dragging, setDragging] = useState(false);
  const phase = useRef<Phase>('idle');
  const start = useRef<{ x: number; y: number; id: number } | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const optsRef = useRef(opts);
  optsRef.current = opts;

  useEffect(() => {
    if (phase.current !== 'dragging') setLocalLevel(level);
  }, [level]);

  useEffect(() => () => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
  }, []);

  const levelAt = (clientX: number): number | null => {
    const rect = ref.current?.getBoundingClientRect();
    if (!rect || rect.width === 0) return null;
    const pct = Math.max(optsRef.current.min, Math.min(100, ((clientX - rect.left) / rect.width) * 100));
    return Math.max(optsRef.current.min, Math.round(pct / 5) * 5);
  };

  const reset = () => {
    phase.current = 'idle';
    start.current = null;
    setDragging(false);
  };

  const onPointerDown = useCallback((e: React.PointerEvent) => {
    if (optsRef.current.ignore?.(e)) return;
    if (e.pointerType === 'mouse' && e.button !== 0) return;
    phase.current = 'pending';
    start.current = { x: e.clientX, y: e.clientY, id: e.pointerId };
  }, []);

  const onPointerMove = useCallback((e: React.PointerEvent) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    if (phase.current === 'pending') {
      const dx = Math.abs(e.clientX - s.x);
      const dy = Math.abs(e.clientY - s.y);
      if (Math.max(dx, dy) < CLASSIFY_PX) return;
      if (dx >= CLASSIFY_PX && dx > 2 * dy) {
        phase.current = 'dragging';
        setDragging(true);
        try { ref.current?.setPointerCapture(e.pointerId); } catch { /* pointer already gone */ }
      } else {
        phase.current = 'abandoned';
        return;
      }
    }
    if (phase.current !== 'dragging') return;
    const next = levelAt(e.clientX);
    if (next === null) return;
    setLocalLevel(next);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => optsRef.current.onAdjust(next), 50);
  }, []);

  const onPointerUp = useCallback((e: React.PointerEvent) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    if (phase.current === 'dragging') {
      if (debounceRef.current) clearTimeout(debounceRef.current);
      const final = levelAt(e.clientX);
      if (final !== null) {
        setLocalLevel(final);
        optsRef.current.onCommit(final);
      }
    } else if (phase.current === 'pending') {
      optsRef.current.onTap?.();
    }
    try { ref.current?.releasePointerCapture(e.pointerId); } catch { /* not captured */ }
    reset();
  }, []);

  const onPointerCancel = useCallback((e: React.PointerEvent) => {
    const s = start.current;
    if (!s || s.id !== e.pointerId) return;
    if (debounceRef.current) {
      clearTimeout(debounceRef.current);
      debounceRef.current = null;
    }
    reset();
    setLocalLevel(level);
  }, [level]);

  return {
    ref,
    localLevel,
    setLocalLevel,
    dragging,
    handlers: { onPointerDown, onPointerMove, onPointerUp, onPointerCancel },
  };
}
