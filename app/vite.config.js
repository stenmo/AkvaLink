import { defineConfig } from 'vite';

// Relative base so the bundle works from Capacitor's capacitor:// / file:// origin.
export default defineConfig({
  base: './',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
});
