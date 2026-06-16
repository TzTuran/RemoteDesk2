/**
 * main.tsx — Application entry point
 *
 * Mounts the root <App /> component into the #app div.
 */

import { render, h } from 'preact';
import { App } from './App';

const rootEl = document.getElementById('app');
if (!rootEl) {
  throw new Error('[main] Could not find #app element in the DOM');
}

render(<App />, rootEl);
