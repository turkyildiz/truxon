/**
 * Minimal ambient types for the Web Speech API *recognition* side.
 *
 * TS 6's `lib.dom.d.ts` already ships the event/result shapes
 * (`SpeechRecognitionEvent`, `SpeechRecognitionResult`, `SpeechRecognitionErrorEvent`,
 * etc.) and the whole `speechSynthesis` surface — but it does NOT declare the
 * `SpeechRecognition` controller interface, its constructor, the legacy
 * `webkitSpeechRecognition` alias, or the `Window` hooks. We declare only those
 * here (reusing the lib's event types) so Trux.tsx stays `any`-free under strict.
 *
 * No import/export: this is a global script declaration file. `moduleDetection:
 * "force" only applies to non-declaration files, so these stay global.
 */

interface SpeechRecognition extends EventTarget {
  lang: string
  continuous: boolean
  interimResults: boolean
  maxAlternatives: number
  start(): void
  stop(): void
  abort(): void
  onresult: ((this: SpeechRecognition, ev: SpeechRecognitionEvent) => unknown) | null
  onerror: ((this: SpeechRecognition, ev: SpeechRecognitionErrorEvent) => unknown) | null
  onend: ((this: SpeechRecognition, ev: Event) => unknown) | null
  onstart: ((this: SpeechRecognition, ev: Event) => unknown) | null
  onnomatch: ((this: SpeechRecognition, ev: SpeechRecognitionEvent) => unknown) | null
}

type SpeechRecognitionCtor = {
  prototype: SpeechRecognition
  new (): SpeechRecognition
}

declare var SpeechRecognition: SpeechRecognitionCtor
declare var webkitSpeechRecognition: SpeechRecognitionCtor

interface Window {
  SpeechRecognition?: SpeechRecognitionCtor
  webkitSpeechRecognition?: SpeechRecognitionCtor
}
