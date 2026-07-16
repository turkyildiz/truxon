/** Render the first pages of a PDF to JPEG blobs in the browser — the
 * vision fallback for scanned rate confirmations that have no text layer.
 * pdfjs is imported lazily so the dispatch page doesn't pay for it until a
 * scanned document actually shows up. */
export async function renderPdfPages(file: File, maxPages = 3): Promise<Blob[]> {
  const pdfjs = await import('pdfjs-dist')
  pdfjs.GlobalWorkerOptions.workerSrc = new URL('pdfjs-dist/build/pdf.worker.min.mjs', import.meta.url).toString()

  const doc = await pdfjs.getDocument({ data: await file.arrayBuffer() }).promise
  const blobs: Blob[] = []
  for (let i = 1; i <= Math.min(doc.numPages, maxPages); i++) {
    const page = await doc.getPage(i)
    const viewport = page.getViewport({ scale: 2 })
    const canvas = document.createElement('canvas')
    canvas.width = viewport.width
    canvas.height = viewport.height
    await page.render({ canvasContext: canvas.getContext('2d')!, viewport }).promise
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.8))
    if (blob) blobs.push(blob)
  }
  return blobs
}
