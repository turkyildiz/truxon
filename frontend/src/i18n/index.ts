import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import en from './locales/en.json'
import es from './locales/es.json'
import ru from './locales/ru.json'
import tr from './locales/tr.json'
import uk from './locales/uk.json'
import pl from './locales/pl.json'
import sr from './locales/sr.json'
import ky from './locales/ky.json'
import uz from './locales/uz.json'
import tk from './locales/tk.json'

/** Languages offered in the switcher. `beta` = machine-drafted, needs a native proofread. */
export const LANGS: { code: string; label: string; beta?: boolean }[] = [
  { code: 'en', label: 'English' },
  { code: 'es', label: 'Español' },
  { code: 'ru', label: 'Русский' },
  { code: 'tr', label: 'Türkçe' },
  { code: 'uk', label: 'Українська' },
  { code: 'pl', label: 'Polski' },
  { code: 'sr', label: 'Srpski' },
  { code: 'ky', label: 'Кыргызча', beta: true },
  { code: 'uz', label: "O'zbekcha", beta: true },
  { code: 'tk', label: 'Türkmençe', beta: true },
]

const STORAGE_KEY = 'truxon-lang'
const saved = typeof localStorage !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null

i18n.use(initReactI18next).init({
  resources: {
    en: { translation: en },
    es: { translation: es },
    ru: { translation: ru },
    tr: { translation: tr },
    uk: { translation: uk },
    pl: { translation: pl },
    sr: { translation: sr },
    ky: { translation: ky },
    uz: { translation: uz },
    tk: { translation: tk },
  },
  lng: saved && LANGS.some((l) => l.code === saved) ? saved : 'en',
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
})

export function setLanguage(code: string) {
  i18n.changeLanguage(code)
  try {
    localStorage.setItem(STORAGE_KEY, code)
  } catch {
    /* ignore */
  }
}

export default i18n
