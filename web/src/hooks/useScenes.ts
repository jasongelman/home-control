import { useState, useEffect, useCallback } from 'react';
import { useUsageTracker } from './useUsageTracker.js';
import type { Scene, SceneDeviceTarget } from '../types/index.js';

export function useScenes() {
  const { trackScene } = useUsageTracker();
  const [scenes, setScenes] = useState<Scene[]>([]);
  const [loading, setLoading] = useState(true);

  const fetchScenes = useCallback(async () => {
    try {
      const res = await fetch('/api/scenes');
      if (res.ok) {
        const data = await res.json();
        setScenes(data);
      }
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { fetchScenes(); }, [fetchScenes]);

  const createScene = useCallback(async (data: { name: string; icon: string; targets: SceneDeviceTarget[] }) => {
    const res = await fetch('/api/scenes', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (res.ok) {
      const scene = await res.json();
      setScenes((prev) => [...prev, scene]);
      return scene;
    }
  }, []);

  const updateScene = useCallback(async (id: string, data: { name: string; icon: string; targets: SceneDeviceTarget[] }) => {
    const res = await fetch(`/api/scenes/${id}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    if (res.ok) {
      const updated = await res.json();
      setScenes((prev) => prev.map((s) => s.id === id ? updated : s));
      return updated;
    }
  }, []);

  const deleteScene = useCallback(async (id: string) => {
    const res = await fetch(`/api/scenes/${id}`, { method: 'DELETE' });
    if (res.ok) {
      setScenes((prev) => prev.filter((s) => s.id !== id));
    }
  }, []);

  const activateScene = useCallback(async (id: string) => {
    await fetch(`/api/scenes/${id}/activate`, { method: 'POST' });
    trackScene(id);
  }, [trackScene]);

  const captureCurrentState = useCallback(async (): Promise<SceneDeviceTarget[]> => {
    const res = await fetch('/api/scenes/capture', { method: 'POST' });
    if (res.ok) {
      const data = await res.json();
      return data.targets;
    }
    return [];
  }, []);

  return { scenes, loading, createScene, updateScene, deleteScene, activateScene, captureCurrentState };
}
