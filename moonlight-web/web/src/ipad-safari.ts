/**
 * ipad-safari.ts
 *
 * Initialisation helpers and capability wrappers specifically for Safari on iPadOS.
 * All exported functions are safe to call on non-Safari platforms — they will
 * gracefully no-op or return sensible defaults.
 */

// ---------------------------------------------------------------------------
// Internal detection helpers
// ---------------------------------------------------------------------------

/**
 * Returns true if the current UA is Safari on iOS/iPadOS.
 * Detects both iPhone UA and the desktop-mode iPad UA introduced in iPadOS 13.
 */
function _isSafariIOS(): boolean {
  const ua = navigator.userAgent;
  const isIOS =
    /iPhone|iPad|iPod/.test(ua) ||
    // iPad in desktop mode reports itself as Macintosh but exposes touch
    (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const isSafari = /^((?!chrome|android|crios|fxios).)*safari/i.test(ua);
  return isIOS && isSafari;
}

/**
 * Returns true if the browser exposes the `navigator.userActivation` API,
 * which is used to gate autoplay and other privileged actions.
 */
function _hasUserActivation(): boolean {
  return typeof (navigator as Navigator & { userActivation?: unknown }).userActivation !== 'undefined';
}

// ---------------------------------------------------------------------------
// Module-level state
// ---------------------------------------------------------------------------

let _initialised = false;

// ---------------------------------------------------------------------------
// Exported: initIPadSafari
// ---------------------------------------------------------------------------

/**
 * Call once at application start.
 *
 * Sets up all necessary polyfills and listeners required for a smooth
 * streaming experience on Safari / iPadOS. Safe to call on every platform;
 * guards are applied internally.
 */
export function initIPadSafari(): void {
  if (_initialised) return;
  _initialised = true;

  if (_isSafariIOS()) {
    // Prevent default touch-selection on the canvas so drags are not
    // interrupted by the iOS text-selection UI.
    document.addEventListener('touchstart', (e) => {
      if ((e.target as HTMLElement).tagName === 'CANVAS') {
        e.preventDefault();
      }
    }, { passive: false });

    // Prevent page zoom on double-tap — relevant when the virtual keyboard
    // toolbar is visible.
    let _lastTap = 0;
    document.addEventListener('touchend', (e) => {
      const now = Date.now();
      if (now - _lastTap < 300) {
        e.preventDefault();
      }
      _lastTap = now;
    }, { passive: false });
  }

  // Log detection result for debugging.
  console.debug(
    `[ipad-safari] isSafariIOS=${_isSafariIOS()} hasUserActivation=${_hasUserActivation()}`,
  );
}

// ---------------------------------------------------------------------------
// Exported: getBestCodec
// ---------------------------------------------------------------------------

/**
 * Probes the browser's VideoDecoder for hardware HEVC support.
 *
 * Resolution order:
 *   1. HEVC (hvc1) — hardware decode on Apple Silicon / A-series chips
 *   2. H.264 (avc1) — universally supported, hardware on all modern devices
 *   3. OpenH264 WASM — software fallback for very old or restricted browsers
 *
 * @returns A promise that resolves to the best available codec identifier.
 */
export async function getBestCodec(): Promise<'hevc' | 'h264' | 'openh264'> {
  if (typeof VideoDecoder === 'undefined') {
    console.warn('[ipad-safari] VideoDecoder API not available — using openh264 fallback');
    return 'openh264';
  }

  try {
    const hevcConfig: VideoDecoderConfig = {
      codec: 'hvc1.1.6.L123.B0',
      hardwareAcceleration: 'prefer-hardware',
    };
    const hevcSupport = await VideoDecoder.isConfigSupported(hevcConfig);
    if (hevcSupport.supported) {
      console.debug('[ipad-safari] HEVC hardware decode supported');
      return 'hevc';
    }
  } catch {
    // isConfigSupported may throw on some browsers; continue to next option.
  }

  try {
    const h264Config: VideoDecoderConfig = {
      codec: 'avc1.640034',
      hardwareAcceleration: 'prefer-hardware',
    };
    const h264Support = await VideoDecoder.isConfigSupported(h264Config);
    if (h264Support.supported) {
      console.debug('[ipad-safari] H.264 hardware decode supported');
      return 'h264';
    }
  } catch {
    // Continue.
  }

  console.warn('[ipad-safari] No hardware VideoDecoder available — falling back to openh264');
  return 'openh264';
}

// ---------------------------------------------------------------------------
// Exported: ensureAudioResumed
// ---------------------------------------------------------------------------

/**
 * Attaches a one-time `pointerdown` listener on `document` that resumes
 * `audioCtx` and then removes itself.
 *
 * Safari requires a user-gesture before an AudioContext is allowed to produce
 * sound. Calling this function immediately after creating the AudioContext
 * ensures audio starts as soon as the user touches the screen.
 *
 * @param ctx - The AudioContext to resume on first user interaction.
 */
export function ensureAudioResumed(ctx: AudioContext): void {
  if (ctx.state === 'running') return;

  const handler = async () => {
    try {
      await ctx.resume();
      console.debug('[ipad-safari] AudioContext resumed');
    } catch (err) {
      console.warn('[ipad-safari] Failed to resume AudioContext:', err);
    } finally {
      document.removeEventListener('pointerdown', handler);
    }
  };

  document.addEventListener('pointerdown', handler, { once: true });
}

// ---------------------------------------------------------------------------
// Exported: requestKeyboardLock
// ---------------------------------------------------------------------------

/**
 * Requests the Keyboard Lock API so that system-level key combinations
 * (Escape, Tab, etc.) are forwarded to the web app instead of being
 * intercepted by the OS or browser.
 *
 * Silently does nothing if the API is unavailable (e.g. iOS Safari).
 *
 * @returns A promise that resolves when the lock is acquired (or skipped).
 */
export async function requestKeyboardLock(): Promise<void> {
  const kbd = (navigator as Navigator & { keyboard?: { lock(keys?: string[]): Promise<void>; unlock(): void } }).keyboard;
  if (!kbd) {
    console.debug('[ipad-safari] Keyboard Lock API not available');
    return;
  }
  try {
    await kbd.lock(['Escape', 'Tab', 'MetaLeft', 'MetaRight', 'AltLeft', 'AltRight']);
    console.debug('[ipad-safari] Keyboard lock acquired');
  } catch (err) {
    console.warn('[ipad-safari] Keyboard lock failed (non-fatal):', err);
  }
}

/**
 * Releases any previously acquired keyboard lock.
 * No-op if the API is unavailable.
 */
export function releaseKeyboardLock(): void {
  const kbd = (navigator as Navigator & { keyboard?: { lock(keys?: string[]): Promise<void>; unlock(): void } }).keyboard;
  kbd?.unlock();
}

// ---------------------------------------------------------------------------
// Exported: requestPointerLock / releasePointerLock
// ---------------------------------------------------------------------------

/**
 * Requests pointer lock on `el` with `unadjustedMovement: true` to receive
 * raw mouse deltas unaffected by OS pointer acceleration.
 *
 * Falls back to the unprefixed or webkit-prefixed form if the options
 * overload is not supported.
 *
 * @param el - The element to lock the pointer to (typically the stream canvas).
 * @returns A promise that resolves when the lock is granted.
 */
export async function requestPointerLock(el: HTMLElement): Promise<void> {
  type ExtendedElement = HTMLElement & {
    requestPointerLock(opts?: { unadjustedMovement?: boolean }): Promise<void> | void;
    webkitRequestPointerLock?(): void;
  };

  const extEl = el as ExtendedElement;

  try {
    // Preferred: options overload (Chrome 88+, Safari 16.4+)
    const result = extEl.requestPointerLock({ unadjustedMovement: true });
    if (result instanceof Promise) await result;
    console.debug('[ipad-safari] Pointer lock acquired (unadjustedMovement=true)');
    return;
  } catch (optErr) {
    // unadjustedMovement may not be supported — try without it.
    console.debug('[ipad-safari] unadjustedMovement not supported, retrying plain lock:', optErr);
  }

  try {
    const result = (extEl.requestPointerLock as () => Promise<void> | void)();
    if (result instanceof Promise) await result;
    console.debug('[ipad-safari] Pointer lock acquired (plain)');
    return;
  } catch {
    // Last resort: webkit prefix
  }

  if (typeof extEl.webkitRequestPointerLock === 'function') {
    extEl.webkitRequestPointerLock();
    console.debug('[ipad-safari] Pointer lock acquired (webkit prefix)');
    return;
  }

  console.warn('[ipad-safari] Pointer lock not available on this platform');
}

/**
 * Exits pointer lock, releasing the cursor back to the OS.
 * No-op if pointer lock is not currently active.
 */
export function releasePointerLock(): void {
  document.exitPointerLock?.();
}

// ---------------------------------------------------------------------------
// Exported: acquireWakeLock
// ---------------------------------------------------------------------------

/**
 * Acquires a Screen Wake Lock to prevent the display from sleeping during
 * an active streaming session.
 *
 * @returns A promise that resolves to the `WakeLockSentinel` if successfully
 *          acquired, or `null` if the API is unavailable or the request fails.
 */
export async function acquireWakeLock(): Promise<WakeLockSentinel | null> {
  if (!('wakeLock' in navigator)) {
    console.debug('[ipad-safari] Wake Lock API not available');
    return null;
  }
  try {
    const sentinel = await navigator.wakeLock.request('screen');
    console.debug('[ipad-safari] Wake lock acquired');
    sentinel.addEventListener('release', () => {
      console.debug('[ipad-safari] Wake lock released by system');
    });
    return sentinel;
  } catch (err) {
    console.warn('[ipad-safari] Failed to acquire wake lock:', err);
    return null;
  }
}
