async function decode(file) {
  try {
    // 新版瀏覽器預設就會依 EXIF 轉正；不傳選項以避免部分 Safari 版本丟錯
    return await createImageBitmap(file)
  } catch {
    const url = URL.createObjectURL(file)
    try {
      const img = new Image()
      img.src = url
      await img.decode()
      return img
    } finally { URL.revokeObjectURL(url) }
  }
}

/** 壓縮成 webp（不支援就 jpeg）、最長邊 1280。經 canvas 重繪會丟掉 EXIF（含 GPS）。 */
export async function compressImage(file, maxSide = 1280, quality = 0.8) {
  const src = await decode(file)
  const w = src.width || src.naturalWidth, h = src.height || src.naturalHeight
  const scale = Math.min(1, maxSide / Math.max(w, h))
  const canvas = document.createElement('canvas')
  canvas.width = Math.round(w * scale)
  canvas.height = Math.round(h * scale)
  canvas.getContext('2d').drawImage(src, 0, 0, canvas.width, canvas.height)
  const toBlob = (type) => new Promise((res) => canvas.toBlob(res, type, quality))
  let blob = await toBlob('image/webp')
  if (!blob || blob.type !== 'image/webp') blob = await toBlob('image/jpeg')
  if (!blob) throw new Error('圖片壓縮失敗')
  return blob
}
