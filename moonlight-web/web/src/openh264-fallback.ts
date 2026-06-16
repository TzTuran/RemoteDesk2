/**
 * openh264-fallback.ts
 *
 * Software H.264 decoder backed by the OpenH264 WASM module.
 *
 * PERFORMANCE WARNING:
 *   This is a pure-software fallback path. Expect significant CPU usage.
 *   Realistic targets on hardware without VideoDecoder support:
 *     - 720p @ 30 fps on modern mid-range devices (iPad Air 2+)
 *     - 1080p may cause frame drops or thermal throttling
 *   Prefer the hardware VideoDecoder path whenever possible.
 *
 * The WASM module is expected at /assets/openh264.wasm.
 * The module must export the C ABI described below.
 *
 * Expected WASM exports:
 *   malloc(size: i32): i32          — allocate heap memory
 *   free(ptr: i32): void            — free heap memory
 *   decoder_create(): i32           — create decoder instance, returns handle
 *   decoder_decode(                 — decode one NAL unit
 *     handle: i32,
 *     nalPtr: i32,
 *     nalLen: i32,
 *     outWidthPtr: i32,
 *     outHeightPtr: i32,
 *     outStridePtr: i32
 *   ): i32                          — returns pointer to I420 output, 0 on error
 *   decoder_destroy(handle: i32): void
 */

// ---------------------------------------------------------------------------
// WASM import types
// ---------------------------------------------------------------------------

interface OpenH264Exports {
  memory: WebAssembly.Memory;
  malloc(size: number): number;
  free(ptr: number): void;
  decoder_create(): number;
  decoder_decode(
    handle: number,
    nalPtr: number,
    nalLen: number,
    outWidthPtr: number,
    outHeightPtr: number,
    outStridePtr: number,
  ): number;
  decoder_destroy(handle: number): void;
}

// ---------------------------------------------------------------------------
// OpenH264Decoder class
// ---------------------------------------------------------------------------

/**
 * Software H.264 decoder using OpenH264 compiled to WebAssembly.
 *
 * Usage:
 * ```ts
 * const dec = new OpenH264Decoder();
 * await dec.init();
 * const frame = await dec.decode(nalUnit);
 * frame.close(); // always close after use
 * dec.destroy();
 * ```
 */
export class OpenH264Decoder {
  private _exports: OpenH264Exports | null = null;
  private _handle = 0;
  private _nalBuf = 0;
  private _nalBufSize = 0;
  private _metaBuf = 0; // 12-byte scratch for out params (3 × i32)

  // ---------------------------------------------------------------------------
  // init
  // ---------------------------------------------------------------------------

  /**
   * Loads the OpenH264 WASM module and initialises the decoder.
   * Must be called (and awaited) before any calls to `decode()`.
   *
   * @throws If the WASM module cannot be fetched or instantiated.
   */
  async init(): Promise<void> {
    const wasmUrl = '/assets/openh264.wasm';

    let instance: WebAssembly.Instance;
    try {
      const result = await WebAssembly.instantiateStreaming(fetch(wasmUrl), {
        env: {
          // Minimal WASI/env stubs required by OpenH264
          abort: (msg: number, file: number, line: number, col: number) => {
            console.error(`[OpenH264] abort at ${file}:${line}:${col} msg=${msg}`);
            throw new Error('OpenH264 WASM aborted');
          },
          emscripten_resize_heap: (_size: number) => false,
        },
        wasi_snapshot_preview1: {
          proc_exit: (code: number) => { throw new Error(`OpenH264 proc_exit(${code})`); },
          fd_close: () => 0,
          fd_write: () => 0,
          fd_seek: () => 0,
        },
      });
      instance = result.instance;
    } catch (err) {
      throw new Error(`[OpenH264Decoder] Failed to load WASM from ${wasmUrl}: ${err}`);
    }

    this._exports = instance.exports as unknown as OpenH264Exports;

    // Create decoder instance
    this._handle = this._exports.decoder_create();
    if (this._handle === 0) {
      throw new Error('[OpenH264Decoder] decoder_create() returned null handle');
    }

    // Allocate scratch buffer for out-params (width, height, stride — 3 × 4 bytes)
    this._metaBuf = this._exports.malloc(12);
    if (this._metaBuf === 0) {
      throw new Error('[OpenH264Decoder] Failed to allocate meta buffer');
    }

    console.debug('[OpenH264Decoder] Initialised');
  }

  // ---------------------------------------------------------------------------
  // decode
  // ---------------------------------------------------------------------------

  /**
   * Decodes a single H.264 NAL unit.
   *
   * The returned `VideoFrame` uses `VideoPixelFormat` `I420` with dimensions
   * taken from the decoder output. The caller **must** call `frame.close()`
   * after use to release the underlying buffer.
   *
   * @param nalUnit - Raw H.264 NAL unit bytes (Annex B or AVCC format).
   * @returns A `VideoFrame` containing the decoded picture, or `null` if the
   *          NAL unit does not produce output (e.g. SPS/PPS parameter sets).
   *
   * @throws If the decoder has not been initialised or an unrecoverable error occurs.
   */
  async decode(nalUnit: Uint8Array): Promise<VideoFrame | null> {
    const exp = this._exports;
    if (!exp || this._handle === 0) {
      throw new Error('[OpenH264Decoder] Not initialised — call init() first');
    }

    // (Re-)allocate NAL input buffer if needed
    if (this._nalBuf === 0 || this._nalBufSize < nalUnit.byteLength) {
      if (this._nalBuf !== 0) exp.free(this._nalBuf);
      this._nalBufSize = Math.max(nalUnit.byteLength, 65_536);
      this._nalBuf = exp.malloc(this._nalBufSize);
      if (this._nalBuf === 0) throw new Error('[OpenH264Decoder] malloc failed for NAL buffer');
    }

    // Copy NAL bytes into WASM heap
    const heap = new Uint8Array(exp.memory.buffer);
    heap.set(nalUnit, this._nalBuf);

    // Decode
    const i420Ptr = exp.decoder_decode(
      this._handle,
      this._nalBuf,
      nalUnit.byteLength,
      this._metaBuf,
      this._metaBuf + 4,
      this._metaBuf + 8,
    );

    if (i420Ptr === 0) {
      // No output frame (parameter set NAL, etc.)
      return null;
    }

    // Read out-params from scratch buffer
    const metaView = new DataView(exp.memory.buffer, this._metaBuf, 12);
    const width  = metaView.getInt32(0, true);
    const height = metaView.getInt32(4, true);
    const stride = metaView.getInt32(8, true);

    if (width <= 0 || height <= 0) return null;

    // Construct I420 planes from WASM heap output
    // Layout: Y plane (stride × height), U plane (stride/2 × height/2), V plane (same as U)
    const ySize  = stride * height;
    const uvSize = (stride >> 1) * (height >> 1);
    const totalSize = ySize + uvSize * 2;

    // Copy from WASM heap into a fresh ArrayBuffer (avoids holding a WASM memory reference)
    const i420 = new Uint8Array(totalSize);
    i420.set(new Uint8Array(exp.memory.buffer, i420Ptr, totalSize));

    // Build VideoFrame from I420 data
    const timestamp = performance.now() * 1_000; // microseconds
    const frame = new VideoFrame(i420, {
      format: 'I420',
      codedWidth: width,
      codedHeight: height,
      timestamp,
      layout: [
        { offset: 0,              stride },
        { offset: ySize,          stride: stride >> 1 },
        { offset: ySize + uvSize, stride: stride >> 1 },
      ],
    });

    return frame;
  }

  // ---------------------------------------------------------------------------
  // destroy
  // ---------------------------------------------------------------------------

  /**
   * Frees all WASM-heap allocations and destroys the decoder instance.
   * After calling `destroy()`, the `OpenH264Decoder` instance must not be used.
   */
  destroy(): void {
    const exp = this._exports;
    if (!exp) return;

    if (this._handle !== 0) {
      exp.decoder_destroy(this._handle);
      this._handle = 0;
    }
    if (this._nalBuf !== 0) {
      exp.free(this._nalBuf);
      this._nalBuf = 0;
    }
    if (this._metaBuf !== 0) {
      exp.free(this._metaBuf);
      this._metaBuf = 0;
    }

    this._exports = null;
    console.debug('[OpenH264Decoder] Destroyed');
  }
}
