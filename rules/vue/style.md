---
paths:
  - "**/*.vue"
---
# Vue single-file components

## Script and props
- When a single-file component uses the Composition API, write it with `<script setup>`; it is the recommended syntax for that combination.
- Declare props with at least their type, for example `defineProps<{ id: number }>()`; Vue then warns in development when a prop is malformed.
- Use `defineModel()` (Vue 3.4+) for a prop consumed with `v-model`; it declares the prop and emits `update:modelValue` when mutated.
- When using type-based `defineProps` on Vue 3.4 or earlier, set defaults with `withDefaults()`.
- Call `defineExpose()` for any binding a parent needs through a template ref; a `<script setup>` component is closed by default.

## Template and styles
- Give every `v-for` a unique `:key`; it is required on components to keep their internal state.
- Do not put `v-if` on the same element as `v-for`; `v-if` is evaluated first, so the iteration variable does not exist yet. Iterate a computed list or wrap in `<template v-for>`.
- Give components multi-word names, except the root `App`, to avoid conflicts with current and future HTML elements.
