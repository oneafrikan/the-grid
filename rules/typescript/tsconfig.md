---
paths:
  - "**/tsconfig*.json"
---
# tsconfig

- In the tsconfig that holds `compilerOptions`, set `"strict": true`; it enables the whole strict family (`strictNullChecks`, `noImplicitAny` and the rest).
- When the output runs in Node.js (TypeScript 4.7 and later), set `"module": "nodenext"`; it implies `"moduleResolution": "nodenext"` and the floating `"target": "esnext"`, and its behaviour tracks the latest stable Node.js.
- When a bundler consumes the output, set `"module": "esnext"` and `"moduleResolution": "bundler"`; `bundler` resolution does not require file extensions on relative imports.
