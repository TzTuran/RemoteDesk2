/**
 * stream-hooks.ts
 *
 * Custom Preact/React hooks that encapsulate all streaming-related WebAPIs:
 * WebRTC peer connection, VideoDecoder, AudioWorklet, binary input channel,
 * and latency probing.
 */

import { useCallback, useEffect, useRef, useState } from 'preact/hooks';
import { ensureAudioResumed } from './ipad-safari';

// ---------------------------------------------------------------------------
// Shared types
// ---------------------------------------------------------------------------

/** ICE server configuration passed to RTCPeerConnection. */
export interface RTCConfig {
  /** List of ICE servers (STUN + optional TURN). */
  iceServers?: RTCIceServer[];
  /** Timeout in ms before declaring ICE as failed. Default: 15 000. */
  iceTimeoutMs?: number;
}

/** Return value of {@link useWebRTC}. */
export interface WebRTCHandle {
  peerConnection: RTCPeerConnection | null;
  connectionState: RTCPeerConnectionState;
  addTrack: (track: MediaStreamTrack, ...streams: MediaStream[]) => RTCRtpSender | null;
  sendData: (channel: string, data: ArrayBuffer | string) => void;
}

/** Return value of {@link useInputChannel}. */
export interface InputChannelHandle {
  sendMouseMove: (x: number, y: number, dx: number, dy: number) => void;
  sendMouseClick: (button: number, pressed: boolean, x: number, y: number) => void;
  sendKeyEvent: (code: number, pressed: boolean, modifiers: number) => void;
  sendGamepadState: (state: GamepadState) => void;
  channelReady: boolean;
}

/** Compact gamepad state snapshot. */
export interface GamepadState {
  index: number;
  /** 16-bit bitmask of button states. */
  buttons: number;
  /** 4 axes, each as a float32. */
  axes: [number, number, number, number];
}

// ---------------------------------------------------------------------------
// useWebRTC
// ---------------------------------------------------------------------------

const DEFAULT_ICE_SERVERS: RTCIceServer[] = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
];

/**
 * Manages the full RTCPeerConnection lifecycle.
 *
 * Creates a new PeerConnection on mount (or when `config` identity changes),
 * wires up ICE negotiation, and exposes helpers for adding tracks and sending
 * data-channel messages.
 *
 * @param config - ICE server configuration and optional timeout.
 */
export function useWebRTC(config: RTCConfig): WebRTCHandle {
  const [connectionState, setConnectionState] = useState<RTCPeerConnectionState>('new');
  const pcRef = useRef<RTCPeerConnection | null>(null);
  const dataChannelsRef = useRef<Map<string, RTCDataChannel>>(new Map());

  useEffect(() => {
    const iceServers = config.iceServers ?? DEFAULT_ICE_SERVERS;
    const pc = new RTCPeerConnection({ iceServers });
    pcRef.current = pc;

    pc.onconnectionstatechange = () => {
      setConnectionState(pc.connectionState);
      console.debug('[useWebRTC] connectionState =', pc.connectionState);
    };

    pc.onicecandidate = (e) => {
      if (e.candidate) {
        console.debug('[useWebRTC] ICE candidate:', e.candidate.type, e.candidate.protocol);
      }
    };

    pc.onicecandidateerror = (e) => {
      console.warn('[useWebRTC] ICE error:', (e as RTCPeerConnectionIceErrorEvent).errorText);
    };

    // ICE timeout watchdog
    const iceTimeout = config.iceTimeoutMs ?? 15_000;
    const watchdog = setTimeout(() => {
      if (pc.iceConnectionState !== 'connected' && pc.iceConnectionState !== 'completed') {
        console.warn('[useWebRTC] ICE timeout — closing connection');
        pc.close();
        setConnectionState('failed');
      }
    }, iceTimeout);

    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
        clearTimeout(watchdog);
      }
    };

    return () => {
      clearTimeout(watchdog);
      pc.close();
      pcRef.current = null;
      dataChannelsRef.current.clear();
      console.debug('[useWebRTC] PeerConnection closed');
    };
  }, [config]);

  const addTrack = useCallback(
    (track: MediaStreamTrack, ...streams: MediaStream[]): RTCRtpSender | null => {
      const pc = pcRef.current;
      if (!pc) return null;
      return pc.addTrack(track, ...streams);
    },
    [],
  );

  const sendData = useCallback((channel: string, data: ArrayBuffer | string) => {
    const pc = pcRef.current;
    if (!pc) return;
    let dc = dataChannelsRef.current.get(channel);
    if (!dc || dc.readyState === 'closed') {
      dc = pc.createDataChannel(channel, { ordered: false, maxRetransmits: 0 });
      dataChannelsRef.current.set(channel, dc);
    }
    if (dc.readyState === 'open') {
      dc.send(data as string);
    }
  }, []);

  return {
    peerConnection: pcRef.current,
    connectionState,
    addTrack,
    sendData,
  };
}

// ---------------------------------------------------------------------------
// useVideoDecoder
// ---------------------------------------------------------------------------

/**
 * Wraps the WebCodecs `VideoDecoder` API.
 *
 * Configures the decoder for `codec`, pipes decoded frames to `onFrame`, and
 * handles errors with automatic recovery (reconfigure after 3 consecutive
 * errors).
 *
 * @param codec  - VideoDecoder codec string (e.g. `'hvc1.1.6.L123.B0'`).
 * @param onFrame - Callback invoked with each decoded `VideoFrame`.
 *                  The caller is responsible for calling `frame.close()`.
 */
export function useVideoDecoder(
  codec: string,
  onFrame: (frame: VideoFrame) => void,
): {
  decode: (chunk: EncodedVideoChunk) => void;
  flush: () => Promise<void>;
  reset: () => void;
} {
  const decoderRef = useRef<VideoDecoder | null>(null);
  const errorCountRef = useRef(0);
  const onFrameRef = useRef(onFrame);
  onFrameRef.current = onFrame;

  const buildDecoder = useCallback(() => {
    if (decoderRef.current) {
      try { decoderRef.current.close(); } catch { /* ignore */ }
    }

    const decoder = new VideoDecoder({
      output: (frame) => {
        errorCountRef.current = 0;
        onFrameRef.current(frame);
      },
      error: (err) => {
        errorCountRef.current += 1;
        console.warn('[useVideoDecoder] decode error:', err, `(count=${errorCountRef.current})`);
        if (errorCountRef.current >= 3) {
          console.warn('[useVideoDecoder] too many errors — reinitialising decoder');
          errorCountRef.current = 0;
          buildDecoder();
        }
      },
    });

    decoder.configure({ codec, hardwareAcceleration: 'prefer-hardware' });
    decoderRef.current = decoder;
    console.debug('[useVideoDecoder] configured codec:', codec);
  }, [codec]);

  useEffect(() => {
    buildDecoder();
    return () => {
      try { decoderRef.current?.close(); } catch { /* ignore */ }
      decoderRef.current = null;
    };
  }, [buildDecoder]);

  const decode = useCallback((chunk: EncodedVideoChunk) => {
    const d = decoderRef.current;
    if (!d || d.state === 'closed') return;
    try {
      d.decode(chunk);
    } catch (err) {
      console.warn('[useVideoDecoder] decode() threw:', err);
    }
  }, []);

  const flush = useCallback(async () => {
    const d = decoderRef.current;
    if (!d || d.state !== 'configured') return;
    try {
      await d.flush();
    } catch (err) {
      console.warn('[useVideoDecoder] flush() threw:', err);
    }
  }, []);

  const reset = useCallback(() => {
    buildDecoder();
  }, [buildDecoder]);

  return { decode, flush, reset };
}

// ---------------------------------------------------------------------------
// useAudioWorklet
// ---------------------------------------------------------------------------

/**
 * Pipes the first incoming audio track from `peerConnection` through a Web
 * Audio `MediaStreamAudioSourceNode` and into the default destination.
 *
 * Also calls `ensureAudioResumed` so that iOS autoplay restrictions are lifted
 * on first user interaction.
 *
 * @param peerConnection - The active RTCPeerConnection (may be null during setup).
 */
export function useAudioWorklet(peerConnection: RTCPeerConnection | null): {
  audioContext: AudioContext | null;
} {
  const audioCtxRef = useRef<AudioContext | null>(null);
  const sourceNodeRef = useRef<MediaStreamAudioSourceNode | null>(null);

  useEffect(() => {
    if (!peerConnection) return;

    const ctx = new AudioContext({ sampleRate: 48_000 });
    audioCtxRef.current = ctx;
    ensureAudioResumed(ctx);

    const handleTrack = (event: RTCTrackEvent) => {
      if (event.track.kind !== 'audio') return;
      const stream = event.streams[0] ?? new MediaStream([event.track]);
      if (sourceNodeRef.current) {
        sourceNodeRef.current.disconnect();
      }
      const source = ctx.createMediaStreamSource(stream);
      sourceNodeRef.current = source;
      source.connect(ctx.destination);
      console.debug('[useAudioWorklet] audio track connected');
    };

    peerConnection.addEventListener('track', handleTrack);

    return () => {
      peerConnection.removeEventListener('track', handleTrack);
      sourceNodeRef.current?.disconnect();
      sourceNodeRef.current = null;
      ctx.close().catch(() => {});
      audioCtxRef.current = null;
    };
  }, [peerConnection]);

  return { audioContext: audioCtxRef.current };
}

// ---------------------------------------------------------------------------
// Binary input encoding helpers
// ---------------------------------------------------------------------------

// Message type constants
const MSG_MOUSE_MOVE   = 0x01;
const MSG_MOUSE_CLICK  = 0x02;
const MSG_KEY_EVENT    = 0x03;
const MSG_GAMEPAD      = 0x04;

/**
 * Encodes a mouse-move event into a compact 17-byte ArrayBuffer.
 *
 * Layout: [type:u8][x:f32][y:f32][dx:f32][dy:f32]
 */
function encodeMouseMove(x: number, y: number, dx: number, dy: number): ArrayBuffer {
  const buf = new ArrayBuffer(17);
  const view = new DataView(buf);
  view.setUint8(0, MSG_MOUSE_MOVE);
  view.setFloat32(1, x, true);
  view.setFloat32(5, y, true);
  view.setFloat32(9, dx, true);
  view.setFloat32(13, dy, true);
  return buf;
}

/**
 * Encodes a mouse-button event into a 14-byte ArrayBuffer.
 *
 * Layout: [type:u8][button:u8][pressed:u8][x:f32][y:f32][pad:u16]
 */
function encodeMouseClick(button: number, pressed: boolean, x: number, y: number): ArrayBuffer {
  const buf = new ArrayBuffer(14);
  const view = new DataView(buf);
  view.setUint8(0, MSG_MOUSE_CLICK);
  view.setUint8(1, button);
  view.setUint8(2, pressed ? 1 : 0);
  view.setFloat32(3, x, true);
  view.setFloat32(7, y, true);
  return buf;
}

/**
 * Encodes a keyboard event into a 7-byte ArrayBuffer.
 *
 * Layout: [type:u8][keyCode:u16][pressed:u8][modifiers:u8][pad:u16]
 */
function encodeKeyEvent(code: number, pressed: boolean, modifiers: number): ArrayBuffer {
  const buf = new ArrayBuffer(7);
  const view = new DataView(buf);
  view.setUint8(0, MSG_KEY_EVENT);
  view.setUint16(1, code, true);
  view.setUint8(3, pressed ? 1 : 0);
  view.setUint8(4, modifiers);
  return buf;
}

/**
 * Encodes a gamepad state snapshot into a 27-byte ArrayBuffer.
 *
 * Layout: [type:u8][index:u8][buttons:u16][axes:4×f32]
 */
function encodeGamepadState(state: GamepadState): ArrayBuffer {
  const buf = new ArrayBuffer(27);
  const view = new DataView(buf);
  view.setUint8(0, MSG_GAMEPAD);
  view.setUint8(1, state.index);
  view.setUint16(2, state.buttons, true);
  view.setFloat32(4, state.axes[0], true);
  view.setFloat32(8, state.axes[1], true);
  view.setFloat32(12, state.axes[2], true);
  view.setFloat32(16, state.axes[3], true);
  return buf;
}

// ---------------------------------------------------------------------------
// useInputChannel
// ---------------------------------------------------------------------------

/**
 * Opens (or reuses) the `input` DataChannel on `peerConnection` and exposes
 * methods for sending binary-encoded input events to the server.
 *
 * The DataChannel is configured as unreliable / unordered to minimise latency.
 *
 * @param peerConnection - Active RTCPeerConnection.
 */
export function useInputChannel(peerConnection: RTCPeerConnection | null): InputChannelHandle {
  const dcRef = useRef<RTCDataChannel | null>(null);
  const [channelReady, setChannelReady] = useState(false);

  useEffect(() => {
    if (!peerConnection) return;

    const dc = peerConnection.createDataChannel('input', {
      ordered: false,
      maxRetransmits: 0,
    });
    dcRef.current = dc;

    dc.onopen = () => {
      setChannelReady(true);
      console.debug('[useInputChannel] DataChannel open');
    };
    dc.onclose = () => {
      setChannelReady(false);
      console.debug('[useInputChannel] DataChannel closed');
    };
    dc.onerror = (e) => {
      console.warn('[useInputChannel] DataChannel error:', e);
    };

    return () => {
      dc.close();
      dcRef.current = null;
      setChannelReady(false);
    };
  }, [peerConnection]);

  const _send = useCallback((buf: ArrayBuffer) => {
    const dc = dcRef.current;
    if (dc?.readyState === 'open') {
      dc.send(buf);
    }
  }, []);

  const sendMouseMove = useCallback(
    (x: number, y: number, dx: number, dy: number) => _send(encodeMouseMove(x, y, dx, dy)),
    [_send],
  );

  const sendMouseClick = useCallback(
    (button: number, pressed: boolean, x: number, y: number) =>
      _send(encodeMouseClick(button, pressed, x, y)),
    [_send],
  );

  const sendKeyEvent = useCallback(
    (code: number, pressed: boolean, modifiers: number) =>
      _send(encodeKeyEvent(code, pressed, modifiers)),
    [_send],
  );

  const sendGamepadState = useCallback(
    (state: GamepadState) => _send(encodeGamepadState(state)),
    [_send],
  );

  return { sendMouseMove, sendMouseClick, sendKeyEvent, sendGamepadState, channelReady };
}

// ---------------------------------------------------------------------------
// useLatencyProbe
// ---------------------------------------------------------------------------

/** Interval between ping messages in milliseconds. */
const PING_INTERVAL_MS = 500;

/**
 * Sends a `ping` message every 500 ms over a dedicated DataChannel and
 * measures round-trip time.
 *
 * The server is expected to echo the same payload back on the same channel.
 * If no server echo is available, latency will read 0.
 *
 * @param peerConnection - Active RTCPeerConnection.
 * @returns `latencyMs` — the latest measured RTT in milliseconds.
 */
export function useLatencyProbe(peerConnection: RTCPeerConnection | null): { latencyMs: number } {
  const [latencyMs, setLatencyMs] = useState(0);
  const dcRef = useRef<RTCDataChannel | null>(null);
  const pendingRef = useRef<Map<number, number>>(new Map());
  const seqRef = useRef(0);

  useEffect(() => {
    if (!peerConnection) return;

    const dc = peerConnection.createDataChannel('ping', { ordered: false, maxRetransmits: 0 });
    dcRef.current = dc;

    dc.onmessage = (e: MessageEvent<ArrayBuffer>) => {
      const view = new DataView(e.data);
      const seq = view.getUint32(0, true);
      const sent = pendingRef.current.get(seq);
      if (sent !== undefined) {
        const rtt = performance.now() - sent;
        pendingRef.current.delete(seq);
        setLatencyMs(Math.round(rtt));
      }
    };

    let intervalId: ReturnType<typeof setInterval>;

    dc.onopen = () => {
      intervalId = setInterval(() => {
        if (dc.readyState !== 'open') return;
        const seq = seqRef.current++ & 0xffffffff;
        const buf = new ArrayBuffer(4);
        new DataView(buf).setUint32(0, seq, true);
        pendingRef.current.set(seq, performance.now());
        // Expire stale entries to avoid memory growth
        if (pendingRef.current.size > 20) {
          const oldest = [...pendingRef.current.keys()][0];
          pendingRef.current.delete(oldest);
        }
        dc.send(buf);
      }, PING_INTERVAL_MS);
    };

    dc.onclose = () => clearInterval(intervalId);

    return () => {
      clearInterval(intervalId);
      dc.close();
      dcRef.current = null;
    };
  }, [peerConnection]);

  return { latencyMs };
}
