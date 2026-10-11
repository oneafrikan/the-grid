---
paths:
  - "**/tsconfig*.json"
---
# tsconfig

- Set `"strict": true`; it enables the whole strict family (`strictNullChecks`, `noImplicitAny` and the rest).
- When the output runs in Node.js, set `"module": "nodenext"`; it implies `"moduleResolution": "nodenext"` and resolves `import` and `require` the way Node.js does.
- When a bundler consumes the output, set `"module": "esnext"` and `"moduleResolution": "bundler"`; `bundler` resolution never requires file extensions on relative imports.
