/**
 * App.tsx
 *
 * Root Preact component for the Moonlight-Web remote-desktop client.
 * Optimised for Safari on iPadOS with full-screen streaming, virtual keyboard,
 * pointer-lock input, and PWA install support.
 */

import { h, Fragment } from 'preact';
import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import {
  initIPadSafari,
  getBestCodec,
  requestKeyboardLock,
  releaseKeyboardLock,
  requestPointerLock,
  releasePointerLock,
  acquireWakeLock,
} from './ipad-safari';
import {
  useWebRTC,
  useVideoDecoder,
  useAudioWorklet,
  useInputChannel,
  useLatencyProbe,
  RTCConfig,
} from './stream-hooks';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type AppState = 'idle' | 'connecting' | 'streaming' | 'error';

interface ConnectionConfig {
  host: string;
  port: number;
}

// Environment-injected defaults (Vite replaces at build time)
const DEFAULT_HOST = (import.meta.env.VITE_DEFAULT_HOST as string | undefined) ?? 'localhost';
const DEFAULT_PORT = parseInt((import.meta.env.VITE_DEFAULT_PORT as string | undefined) ?? '47984', 10);

// ---------------------------------------------------------------------------
// Styles (dark theme, iPad-optimised touch targets ≥44 px)
// ---------------------------------------------------------------------------

const COLORS = {
  bg: '#0d1117',
  surface: '#161b22',
  border: '#30363d',
  accent: '#58a6ff',
  accentHover: '#79b8ff',
  text: '#e6edf3',
  muted: '#8b949e',
  danger: '#f85149',
  success: '#3fb950',
};

const css: Record<string, h.JSX.CSSProperties> = {
  root: {
    margin: 0,
    padding: 0,
    width: '100vw',
    height: '100vh',
    background: COLORS.bg,
    color: COLORS.text,
    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Display", "Helvetica Neue", sans-serif',
    display: 'flex',
    flexDirection: 'column',
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
    userSelect: 'none',
    WebkitUserSelect: 'none',
  },
  connectCard: {
    background: COLORS.surface,
    border: `1px solid ${COLORS.border}`,
    borderRadius: 16,
    padding: '36px 40px',
    minWidth: 340,
    maxWidth: 440,
    width: '90vw',
    display: 'flex',
    flexDirection: 'column',
    gap: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: 600,
    margin: 0,
    letterSpacing: '-0.5px',
  },
  label: {
    fontSize: 13,
    fontWeight: 500,
    color: COLORS.muted,
    marginBottom: 6,
    display: 'block',
  },
  input: {
    width: '100%',
    height: 48,
    background: COLORS.bg,
    border: `1px solid ${COLORS.border}`,
    borderRadius: 10,
    color: COLORS.text,
    fontSize: 16,
    padding: '0 14px',
    boxSizing: 'border-box',
    outline: 'none',
    appearance: 'none',
    WebkitAppearance: 'none',
  },
  button: {
    minHeight: 48,
    borderRadius: 10,
    border: 'none',
    background: COLORS.accent,
    color: '#fff',
    fontWeight: 600,
    fontSize: 16,
    cursor: 'pointer',
    padding: '0 24px',
    transition: 'background 0.15s',
    touchAction: 'manipulation',
  },
  buttonDanger: {
    background: COLORS.danger,
  },
  badge: {
    position: 'absolute',
    top: 16,
    right: 16,
    background: 'rgba(0,0,0,0.6)',
    backdropFilter: 'blur(8px)',
    WebkitBackdropFilter: 'blur(8px)',
    border: `1px solid ${COLORS.border}`,
    borderRadius: 8,
    padding: '4px 10px',
    fontSize: 13,
    fontVariantNumeric: 'tabular-nums',
    color: COLORS.text,
    pointerEvents: 'none' as const,
  },
  toolbar: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    height: 60,
    background: 'rgba(13,17,23,0.85)',
    backdropFilter: 'blur(12px)',
    WebkitBackdropFilter: 'blur(12px)',
    borderTop: `1px solid ${COLORS.border}`,
    display: 'flex',
    alignItems: 'center',
    gap: 4,
    padding: '0 12px',
    flexShrink: 0,
  },
  toolbarBtn: {
    minWidth: 44,
    minHeight: 44,
    borderRadius: 10,
    border: `1px solid ${COLORS.border}`,
    background: 'transparent',
    color: COLORS.text,
    fontSize: 20,
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    touchAction: 'manipulation',
  },
  toolbarBtnActive: {
    background: COLORS.accent,
    border: `1px solid ${COLORS.accent}`,
    color: '#fff',
  },
  errorMsg: {
    color: COLORS.danger,
    fontSize: 14,
    marginTop: -8,
  },
  installBanner: {
    position: 'fixed',
    bottom: 72,
    left: '50%',
    transform: 'translateX(-50%)',
    background: COLORS.surface,
    border: `1px solid ${COLORS.border}`,
    borderRadius: 14,
    padding: '14px 20px',
    display: 'flex',
    alignItems: 'center',
    gap: 16,
    boxShadow: '0 8px 32px rgba(0,0,0,0.4)',
    zIndex: 100,
    maxWidth: '90vw',
  },
  canvas: {
    display: 'block',
    width: '100vw',
    height: '100vh',
    background: '#000',
    cursor: 'none',
    touchAction: 'none',
  },
};

// ---------------------------------------------------------------------------
// Helper: PIN input dots
// ---------------------------------------------------------------------------

function PinDots({ value }: { value: string }) {
  return (
    <div style={{ display: 'flex', gap: 10, justifyContent: 'center', marginTop: 4 }}>
      {[0, 1, 2, 3].map((i) => (
        <div
          key={i}
          style={{
            width: 14,
            height: 14,
            borderRadius: '50%',
            background: i < value.length ? COLORS.accent : COLORS.border,
            transition: 'background 0.15s',
          }}
        />
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main App component
// ---------------------------------------------------------------------------

const DEFAULT_RTC_CONFIG: RTCConfig = {
  iceServers: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
  ],
  iceTimeoutMs: 20_000,
};

export function App() {
  // --- App state ---
  const [appState, setAppState] = useState<AppState>('idle');
  const [errorMsg, setErrorMsg] = useState('');

  // --- Connection form ---
  const [host, setHost] = useState(DEFAULT_HOST);
  const [port] = useState(DEFAULT_PORT);
  const [pin, setPin] = useState('');

  // --- Codec ---
  const [codec, setCodec] = useState<'hevc' | 'h264' | 'openh264'>('h264');

  // --- WebRTC ---
  const { peerConnection, connectionState } = useWebRTC(DEFAULT_RTC_CONFIG);

  // --- Video ---
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const ctxRef = useRef<CanvasRenderingContext2D | null>(null);

  const handleFrame = useCallback((frame: VideoFrame) => {
    const canvas = canvasRef.current;
    if (!canvas) { frame.close(); return; }
    if (!ctxRef.current) {
      ctxRef.current = canvas.getContext('2d');
    }
    const ctx2d = ctxRef.current;
    if (!ctx2d) { frame.close(); return; }
    canvas.width = frame.displayWidth;
    canvas.height = frame.displayHeight;
    ctx2d.drawImage(frame, 0, 0);
    frame.close();
  }, []);

  const videoCodecString = codec === 'hevc' ? 'hvc1.1.6.L123.B0' : 'avc1.640034';
  const { decode } = useVideoDecoder(videoCodecString, handleFrame);

  // --- Audio ---
  useAudioWorklet(peerConnection);

  // --- Input ---
  const {
    sendMouseMove,
    sendMouseClick,
    sendKeyEvent,
    sendGamepadState,
    channelReady,
  } = useInputChannel(peerConnection);

  // --- Latency ---
  const { latencyMs } = useLatencyProbe(peerConnection);

  // --- UI state ---
  const [pointerLocked, setPointerLocked] = useState(false);
  const [showVirtualKbd, setShowVirtualKbd] = useState(false);
  const [showToolbar, setShowToolbar] = useState(true);
  const wakeLockRef = useRef<WakeLockSentinel | null>(null);

  // --- PWA install ---
  const [installPrompt, setInstallPrompt] = useState<Event & { prompt(): Promise<void> } | null>(null);
  const [showInstallBanner, setShowInstallBanner] = useState(false);

  // ---------------------------------------------------------------------------
  // On mount: initialise iPad-Safari helpers, detect codec
  // ---------------------------------------------------------------------------
  useEffect(() => {
    initIPadSafari();

    getBestCodec().then((best) => {
      setCodec(best);
      console.debug('[App] Best codec:', best);
    });

    // PWA install prompt
    const onBeforeInstall = (e: Event) => {
      e.preventDefault();
      setInstallPrompt(e as Event & { prompt(): Promise<void> });
      setShowInstallBanner(true);
    };
    window.addEventListener('beforeinstallprompt', onBeforeInstall);

    return () => {
      window.removeEventListener('beforeinstallprompt', onBeforeInstall);
    };
  }, []);

  // ---------------------------------------------------------------------------
  // Handle connection state changes from WebRTC
  // ---------------------------------------------------------------------------
  useEffect(() => {
    if (connectionState === 'connected') {
      setAppState('streaming');
    } else if (connectionState === 'failed' || connectionState === 'disconnected') {
      if (appState === 'streaming' || appState === 'connecting') {
        setErrorMsg('Connection lost. Please try again.');
        setAppState('error');
      }
    }
  }, [connectionState, appState]);

  // ---------------------------------------------------------------------------
  // Streaming: acquire wake lock + keyboard lock
  // ---------------------------------------------------------------------------
  useEffect(() => {
    if (appState !== 'streaming') return;

    requestKeyboardLock();
    acquireWakeLock().then((s) => { wakeLockRef.current = s; });

    return () => {
      releaseKeyboardLock();
      wakeLockRef.current?.release().catch(() => {});
    };
  }, [appState]);

  // ---------------------------------------------------------------------------
  // Pointer lock management
  // ---------------------------------------------------------------------------
  const togglePointerLock = useCallback(async () => {
    if (pointerLocked) {
      releasePointerLock();
      setPointerLocked(false);
    } else {
      const canvas = canvasRef.current;
      if (canvas) {
        await requestPointerLock(canvas);
        setPointerLocked(true);
      }
    }
  }, [pointerLocked]);

  useEffect(() => {
    const onLockChange = () => {
      setPointerLocked(document.pointerLockElement !== null);
    };
    document.addEventListener('pointerlockchange', onLockChange);
    return () => document.removeEventListener('pointerlockchange', onLockChange);
  }, []);

  // ---------------------------------------------------------------------------
  // Canvas input events → DataChannel
  // ---------------------------------------------------------------------------
  const handleMouseMove = useCallback(
    (e: MouseEvent) => {
      if (!channelReady) return;
      sendMouseMove(e.clientX, e.clientY, e.movementX, e.movementY);
    },
    [channelReady, sendMouseMove],
  );

  const handleMouseDown = useCallback(
    (e: MouseEvent) => {
      if (!channelReady) return;
      sendMouseClick(e.button, true, e.clientX, e.clientY);
    },
    [channelReady, sendMouseClick],
  );

  const handleMouseUp = useCallback(
    (e: MouseEvent) => {
      if (!channelReady) return;
      sendMouseClick(e.button, false, e.clientX, e.clientY);
    },
    [channelReady, sendMouseClick],
  );

  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (!channelReady) return;
      e.preventDefault();
      sendKeyEvent(e.keyCode, true, _modifiers(e));
    },
    [channelReady, sendKeyEvent],
  );

  const handleKeyUp = useCallback(
    (e: KeyboardEvent) => {
      if (!channelReady) return;
      e.preventDefault();
      sendKeyEvent(e.keyCode, false, _modifiers(e));
    },
    [channelReady, sendKeyEvent],
  );

  // Gamepad polling
  useEffect(() => {
    if (appState !== 'streaming') return;
    let rafId: number;
    const poll = () => {
      const gamepads = navigator.getGamepads?.() ?? [];
      for (const gp of gamepads) {
        if (!gp) continue;
        const buttons = gp.buttons.reduce(
          (mask, btn, i) => mask | ((btn.pressed ? 1 : 0) << i),
          0,
        );
        sendGamepadState({
          index: gp.index,
          buttons,
          axes: [gp.axes[0] ?? 0, gp.axes[1] ?? 0, gp.axes[2] ?? 0, gp.axes[3] ?? 0],
        });
      }
      rafId = requestAnimationFrame(poll);
    };
    rafId = requestAnimationFrame(poll);
    return () => cancelAnimationFrame(rafId);
  }, [appState, sendGamepadState]);

  // ---------------------------------------------------------------------------
  // Connect handler
  // ---------------------------------------------------------------------------
  const handleConnect = useCallback(async () => {
    if (!pin || pin.length < 4) {
      setErrorMsg('Please enter a 4-digit PIN.');
      return;
    }
    setErrorMsg('');
    setAppState('connecting');

    try {
      // Initiate signalling via REST API (proxied to /api/)
      const resp = await fetch('/api/pair', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ host, port, pin }),
      });
      if (!resp.ok) {
        throw new Error(`Server returned ${resp.status}`);
      }
      const { offer } = await resp.json() as { offer: RTCSessionDescriptionInit };
      if (!peerConnection) throw new Error('PeerConnection not ready');
      await peerConnection.setRemoteDescription(offer);
      const answer = await peerConnection.createAnswer();
      await peerConnection.setLocalDescription(answer);
      await fetch('/api/answer', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ answer }),
      });
    } catch (err) {
      console.error('[App] Connect error:', err);
      setErrorMsg(err instanceof Error ? err.message : 'Connection failed');
      setAppState('error');
    }
  }, [host, pin, port, peerConnection]);

  // ---------------------------------------------------------------------------
  // PWA install handler
  // ---------------------------------------------------------------------------
  const handleInstall = useCallback(async () => {
    if (!installPrompt) return;
    await installPrompt.prompt();
    setShowInstallBanner(false);
    setInstallPrompt(null);
  }, [installPrompt]);

  // ---------------------------------------------------------------------------
  // Render: Connection screen
  // ---------------------------------------------------------------------------
  if (appState === 'idle' || appState === 'error') {
    return (
      <div style={css.root}>
        <div style={css.connectCard}>
          <h1 style={css.title}>Remote Desktop</h1>

          <div>
            <label style={css.label}>Host address</label>
            <input
              style={css.input}
              type="text"
              value={host}
              onInput={(e) => setHost((e.target as HTMLInputElement).value)}
              placeholder="192.168.1.100"
              autoCapitalize="off"
              autoCorrect="off"
              spellCheck={false}
            />
          </div>

          <div>
            <label style={css.label}>PIN (4 digits)</label>
            <input
              style={css.input}
              type="tel"
              inputMode="numeric"
              pattern="[0-9]*"
              maxLength={4}
              value={pin}
              onInput={(e) => setPin((e.target as HTMLInputElement).value.replace(/\D/g, '').slice(0, 4))}
              placeholder="0000"
            />
            <PinDots value={pin} />
          </div>

          {errorMsg && <p style={css.errorMsg}>{errorMsg}</p>}

          <button style={css.button} onClick={handleConnect}>
            Connect
          </button>

          {showInstallBanner && (
            <button
              style={{ ...css.button, background: COLORS.surface, color: COLORS.accent, border: `1px solid ${COLORS.accent}` }}
              onClick={handleInstall}
            >
              Add to Home Screen
            </button>
          )}
        </div>

        {showInstallBanner && (
          <div style={css.installBanner}>
            <span style={{ fontSize: 28 }}>📲</span>
            <div>
              <div style={{ fontWeight: 600, fontSize: 15 }}>Install Remote Desktop</div>
              <div style={{ color: COLORS.muted, fontSize: 13 }}>For the best full-screen experience</div>
            </div>
            <button style={{ ...css.button, minHeight: 40, fontSize: 14 }} onClick={handleInstall}>
              Install
            </button>
            <button
              onClick={() => setShowInstallBanner(false)}
              style={{ background: 'none', border: 'none', color: COLORS.muted, cursor: 'pointer', fontSize: 20, minWidth: 44, minHeight: 44 }}
            >
              ×
            </button>
          </div>
        )}
      </div>
    );
  }

  // ---------------------------------------------------------------------------
  // Render: Connecting spinner
  // ---------------------------------------------------------------------------
  if (appState === 'connecting') {
    return (
      <div style={css.root}>
        <div style={{ textAlign: 'center', display: 'flex', flexDirection: 'column', gap: 16, alignItems: 'center' }}>
          <Spinner />
          <p style={{ color: COLORS.muted, fontSize: 15, margin: 0 }}>Connecting to {host}…</p>
          <button
            style={{ ...css.button, ...css.buttonDanger, marginTop: 8 }}
            onClick={() => { peerConnection?.close(); setAppState('idle'); }}
          >
            Cancel
          </button>
        </div>
      </div>
    );
  }

  // ---------------------------------------------------------------------------
  // Render: Streaming screen
  // ---------------------------------------------------------------------------
  return (
    <div style={{ position: 'relative', width: '100vw', height: '100vh', background: '#000', overflow: 'hidden' }}>
      <canvas
        id="stream-canvas"
        ref={canvasRef}
        style={css.canvas}
        onMouseMove={handleMouseMove}
        onMouseDown={handleMouseDown}
        onMouseUp={handleMouseUp}
        onKeyDown={handleKeyDown}
        onKeyUp={handleKeyUp}
        tabIndex={0}
      />

      {/* Latency badge */}
      <div style={css.badge}>
        {latencyMs > 0 ? `${latencyMs} ms` : '— ms'}
      </div>

      {/* Toolbar */}
      {showToolbar && (
        <div style={css.toolbar}>
          {/* Pointer lock */}
          <button
            style={{ ...css.toolbarBtn, ...(pointerLocked ? css.toolbarBtnActive : {}) }}
            onClick={togglePointerLock}
            title={pointerLocked ? 'Release pointer' : 'Lock pointer'}
          >
            🖱
          </button>

          {/* Virtual keyboard */}
          <button
            style={{ ...css.toolbarBtn, ...(showVirtualKbd ? css.toolbarBtnActive : {}) }}
            onClick={() => setShowVirtualKbd((v) => !v)}
            title="Toggle keyboard"
          >
            ⌨
          </button>

          {/* Spacer */}
          <div style={{ flex: 1 }} />

          {/* Disconnect */}
          <button
            style={{ ...css.toolbarBtn, border: `1px solid ${COLORS.danger}`, color: COLORS.danger }}
            onClick={() => {
              peerConnection?.close();
              releasePointerLock();
              setPointerLocked(false);
              setAppState('idle');
            }}
            title="Disconnect"
          >
            ✕
          </button>

          {/* Hide toolbar */}
          <button
            style={css.toolbarBtn}
            onClick={() => setShowToolbar(false)}
            title="Hide toolbar"
          >
            ▾
          </button>
        </div>
      )}

      {/* Show toolbar button when hidden */}
      {!showToolbar && (
        <button
          style={{
            position: 'absolute',
            bottom: 16,
            right: 16,
            minWidth: 44,
            minHeight: 44,
            borderRadius: 22,
            background: 'rgba(0,0,0,0.6)',
            border: `1px solid ${COLORS.border}`,
            color: COLORS.text,
            fontSize: 20,
            cursor: 'pointer',
            backdropFilter: 'blur(8px)',
            WebkitBackdropFilter: 'blur(8px)',
          }}
          onClick={() => setShowToolbar(true)}
        >
          ▴
        </button>
      )}

      {/* Virtual keyboard input — hidden but focused to capture key events */}
      {showVirtualKbd && (
        <input
          style={{
            position: 'absolute',
            bottom: showToolbar ? 68 : 16,
            left: '50%',
            transform: 'translateX(-50%)',
            width: 1,
            height: 1,
            opacity: 0.01,
            border: 'none',
            outline: 'none',
            background: 'transparent',
          }}
          autoFocus
          onKeyDown={handleKeyDown}
          onKeyUp={handleKeyUp}
          inputMode="text"
        />
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Spinner sub-component
// ---------------------------------------------------------------------------

function Spinner() {
  return (
    <div
      style={{
        width: 48,
        height: 48,
        border: `4px solid ${COLORS.border}`,
        borderTopColor: COLORS.accent,
        borderRadius: '50%',
        animation: 'spin 0.8s linear infinite',
      }}
    >
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Utility: keyboard modifier bitmask
// ---------------------------------------------------------------------------

function _modifiers(e: KeyboardEvent): number {
  return (
    (e.shiftKey ? 0x01 : 0) |
    (e.ctrlKey  ? 0x02 : 0) |
    (e.altKey   ? 0x04 : 0) |
    (e.metaKey  ? 0x08 : 0)
  );
}

export default App;
