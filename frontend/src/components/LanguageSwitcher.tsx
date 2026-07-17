import { useTranslation } from 'react-i18next'
import { LANGS, setLanguage } from '../i18n'

/** Compact language picker for the top bar. */
export default function LanguageSwitcher() {
  const { i18n, t } = useTranslation()
  return (
    <select
      aria-label={t('common.language')}
      value={i18n.language}
      onChange={(e) => setLanguage(e.target.value)}
      className="rounded-lg border border-line bg-surface px-2 py-2 text-sm text-body hover:bg-surface-2"
      title={t('common.language')}
    >
      {LANGS.map((l) => (
        <option key={l.code} value={l.code}>
          {l.label}
          {l.beta ? ' (β)' : ''}
        </option>
      ))}
    </select>
  )
}
