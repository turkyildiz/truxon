/** Drag-and-drop / file-picker zone for PDF-driven quick entry. */
import { useState } from 'react'
import { Card } from './ui'

interface Props {
  title: string
  hint: string
  busy: boolean
  note: string
  onFile: (file: File) => void
}

export default function PdfDrop({ title, hint, busy, note, onFile }: Props) {
  const [dragOver, setDragOver] = useState(false)

  return (
    <Card title={title}>
      <div
        onDragOver={(e) => {
          e.preventDefault()
          setDragOver(true)
        }}
        onDragLeave={() => setDragOver(false)}
        onDrop={(e) => {
          e.preventDefault()
          setDragOver(false)
          const file = e.dataTransfer.files?.[0]
          if (file?.type === 'application/pdf') onFile(file)
        }}
        className={`flex flex-col items-center justify-center rounded-xl border-2 border-dashed p-6 text-center transition-colors ${
          dragOver ? 'border-navy-600 bg-navy-50' : 'border-slate-300'
        }`}
      >
        <div className="text-3xl">📄</div>
        <p className="mt-2 text-sm font-medium">{hint}</p>
        <p className="text-xs text-slate-500">or</p>
        <label className="mt-2 cursor-pointer rounded-lg bg-navy-700 px-4 py-2 text-sm font-medium text-white hover:bg-navy-800">
          {busy ? 'Extracting…' : 'Choose PDF'}
          <input
            type="file"
            accept="application/pdf"
            className="hidden"
            onChange={(e) => e.target.files?.[0] && onFile(e.target.files[0])}
          />
        </label>
        {note && <p className="mt-3 text-sm text-navy-700">{note}</p>}
      </div>
    </Card>
  )
}
